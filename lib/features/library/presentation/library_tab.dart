import '../../../app/presentation/browse_page_scroll.dart';
import 'library_tree_list.dart';
import 'library_providers.dart';
import 'library_tab_edit.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../application/library_facade.dart';
import '../application/remote_library_controller.dart';
import '../domain/library_node.dart';
import '../domain/remote_media_source.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/library_scanner_service.dart';
import '../application/library_catalog.dart';
import '../application/library_scan_coordinator.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/bold_add_icon.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_edit_icon.dart';
import 'audio_detail_sheet.dart' show showAudioDetailEditor;
import 'dlsite_metadata_batch_page.dart';
import 'library_scan_feedback.dart';
import '../../../app/theme/app_styles.dart';

import '../../../app/presentation/main_tab_state_mixin.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_empty_scan.dart';
import 'library_search_page.dart';
import 'remote_library_work_detail.dart';
import 'remote_source_sheets.dart';
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
    this.isLandscapeLayout,
  });

  final int tabIndex;
  final ValueListenable<int>? activeTabIndexListenable;
  final ValueListenable<int>? activeSectionListenable;
  final int sectionIndex;
  final bool? isLandscapeLayout;

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with WidgetsBindingObserver, MainTabStateMixin<LibraryTab> {
  LibraryScanCoordinator get _scanCoordinator =>
      ref.read(libraryScanCoordinatorProvider);

  @override
  double get defaultHeaderHeight => AppPageHeaderMetrics.expandedToolbarHeight;

  late bool _wasSelected;
  ModalRoute<dynamic>? _route;
  bool _covered = false;

  bool get _isSelected =>
      (widget.activeTabIndexListenable == null ||
          widget.activeTabIndexListenable!.value == tabIndex) &&
      (widget.activeSectionListenable == null ||
          widget.activeSectionListenable!.value == widget.sectionIndex);

  bool get _isActive =>
      !_covered && (_route?.isCurrent ?? true) && _isSelected;

  bool get _canStartStartupRefresh {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return _isActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  @override
  bool get handlesScrollToTop => _isActive;

  void _handleActiveTabChanged() {
    if (!mounted) return;
    final selected = _isSelected;
    if (selected == _wasSelected) return;
    _wasSelected = selected;
    _handleActivityChanged();
  }

  void _handleActivityChanged() {
    if (_isActive) {
      final libraryFacade = ref.read(libraryFacadeProvider);
      final state = libraryFacade.state;
      if (state.isInitialized) {
        _ensureCardSnapshot(
          libraryFacade: libraryFacade,
          snapshotRevision: state.treeSnapshotRevision,
        );
      }
      _ensureStartupRefreshStarted();
      if (_startupRefreshWaiting &&
          !UiInteractionCoordinator.instance.isInteracting) {
        _scheduleStartupRefreshAfter(const Duration(milliseconds: 500));
      }
    } else {
      UiInteractionCoordinator.instance.cancelCommit(_cardSnapshotCommitKey);
      _cardSnapshotRequestRevision = null;
      _startupRefreshIdleTimer?.cancel();
      _startupRefreshIdleTimer = null;
    }
  }

  static const Object _localLibraryStackId = Object();

  Timer? _startupRefreshIdleTimer;
  bool _startupRefreshStarted = false;
  bool _startupRefreshWaiting = false;
  bool _isSelectionMode = false;
  bool _hasWatchedLibrarySort = false;
  final ValueNotifier<bool> _localProjectionAvailable = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<int> _selectionVersion = ValueNotifier<int>(0);
  final Set<String> _selectedLibraryPaths = <String>{};
  final Set<String> _selectedRemoteWorkIds = <String>{};
  String? _lastObservedSourceId;
  List<String> _knownRemoteSourceIds = const <String>[];
  int _renderedLibraryItemCount = 1;
  bool _pendingLibraryIndexSync = false;
  late final ValueNotifier<int> _activeLibraryIndex;

  void _handleProjectionAvailabilityChanged(bool available) {
    if (_localProjectionAvailable.value == available) return;
    _localProjectionAvailable.value = available;
  }

  final _localScrollController = WindowsSmoothScrollController();
  final Map<String, WindowsSmoothScrollController> _remoteScrollControllers =
      <String, WindowsSmoothScrollController>{};
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey();
  int? _cardSnapshotRequestRevision;
  String get _cardSnapshotCommitKey =>
      'library_card_snapshot_${identityHashCode(this)}';

  WindowsSmoothScrollController _scrollControllerForRemote(String sourceId) =>
      _remoteScrollControllers.putIfAbsent(
        sourceId,
        WindowsSmoothScrollController.new,
      );

  ScrollController _scrollControllerForSourceId(String? sourceId) =>
      sourceId == null
      ? _localScrollController
      : _scrollControllerForRemote(sourceId);

  int _resolveLibraryIndex(
    String? selectedSourceId,
    List<String> remoteSourceIds,
  ) {
    if (selectedSourceId == null) return 0;
    final index = remoteSourceIds.indexOf(selectedSourceId);
    return index >= 0 ? index + 1 : 0;
  }

  void _handleRemoteLibraryChanged(RemoteLibraryController controller) {
    if (!mounted) return;
    final nextSourceIds = <String>[
      for (final source in controller.sources) source.id,
    ];
    final nextSelectedId = controller.selectedSourceId;
    if (_lastObservedSourceId != nextSelectedId) {
      _lastObservedSourceId = nextSelectedId;
      if (_isSelectionMode) {
        setState(() {
          _isSelectionMode = false;
          _selectedLibraryPaths.clear();
          _selectedRemoteWorkIds.clear();
          _selectionVersion.value++;
        });
      }
    }

    final activeIds = nextSourceIds.toSet();
    final staleControllers = <WindowsSmoothScrollController>[];
    for (final entry in _remoteScrollControllers.entries.toList()) {
      if (!activeIds.contains(entry.key)) {
        staleControllers.add(entry.value);
        _remoteScrollControllers.remove(entry.key);
      }
    }
    if (staleControllers.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final scrollController in staleControllers) {
          scrollController.dispose();
        }
      });
    }

    final nextIndex = _resolveLibraryIndex(nextSelectedId, nextSourceIds);
    final sourcesChanged = !listEquals(_knownRemoteSourceIds, nextSourceIds);
    if (!sourcesChanged) {
      if (_activeLibraryIndex.value != nextIndex) {
        _activeLibraryIndex.value = nextIndex;
      }
      return;
    }

    _knownRemoteSourceIds = nextSourceIds;
    if (nextIndex < _renderedLibraryItemCount) {
      if (_activeLibraryIndex.value != nextIndex) {
        _activeLibraryIndex.value = nextIndex;
      }
      return;
    }

    if (_pendingLibraryIndexSync) return;
    _pendingLibraryIndexSync = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingLibraryIndexSync = false;
      if (!mounted) return;
      final latest = ref.read(remoteLibraryControllerProvider);
      final latestIds = <String>[
        for (final source in latest.sources) source.id,
      ];
      _knownRemoteSourceIds = latestIds;
      final resolved = _resolveLibraryIndex(latest.selectedSourceId, latestIds);
      if (resolved < _renderedLibraryItemCount &&
          _activeLibraryIndex.value != resolved) {
        _activeLibraryIndex.value = resolved;
      }
    });
  }

  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollControllerForSourceId(
    ref.read(remoteLibraryControllerProvider).selectedSourceId,
  );

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppSearchPageRoute(
        context: context,
        child: const LibrarySearchPage(),
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
        SortOption(
          value: LibrarySortCriterion.userRating,
          label: i18n.tr('sort_user_rating'),
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
    final remoteSource = ref.read(remoteLibraryControllerProvider).selectedSource;
    await Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: DlsiteMetadataBatchPage(remoteSourceId: remoteSource?.id),
      ),
    );
  }

  void _enterSelectionMode(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedRemoteWorkIds.clear();
      _selectedLibraryPaths
        ..clear()
        ..add(selectionKeyForLibraryNode(node));
      _selectionVersion.value++;
    });
  }

  void _enterRemoteSelectionMode(RemoteLibraryWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths.clear();
      _selectedRemoteWorkIds
        ..clear()
        ..add(work.workId);
      _selectionVersion.value++;
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedLibraryPaths.clear();
      _selectedRemoteWorkIds.clear();
      _selectionVersion.value++;
    });
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted ||
        !_isSelectionMode ||
        !_isActive ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _exitSelectionMode();
    return true;
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
      _selectionVersion.value++;
    });
  }

  void _toggleRemoteSelection(RemoteLibraryWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (!_selectedRemoteWorkIds.add(work.workId)) {
        _selectedRemoteWorkIds.remove(work.workId);
        if (_selectedRemoteWorkIds.isEmpty) _isSelectionMode = false;
      }
      _selectionVersion.value++;
    });
  }

  void _toggleSelectAllRemote(List<RemoteLibraryWork> visibleWorks) {
    if (visibleWorks.isEmpty) return;
    final visibleIds = <String>[for (final w in visibleWorks) w.workId];
    final allSelected = visibleIds.every(_selectedRemoteWorkIds.contains);
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (allSelected) {
        _selectedRemoteWorkIds.clear();
      } else {
        _selectedRemoteWorkIds
          ..clear()
          ..addAll(visibleIds);
      }
      _selectionVersion.value++;
    });
  }

  void _toggleSelectAllLibrary(List<LibraryNode> tree) {
    final selectableKeys = <String>[
      for (final node in tree)
        if (isSelectableLibraryNode(node)) selectionKeyForLibraryNode(node),
    ];
    if (selectableKeys.isEmpty) return;
    final allSelected = selectableKeys.every(_selectedLibraryPaths.contains);
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (allSelected) {
        _selectedLibraryPaths.clear();
      } else {
        _selectedLibraryPaths
          ..clear()
          ..addAll(selectableKeys);
      }
      _selectionVersion.value++;
    });
  }

  Future<void> _scheduleWatchedFoldersRefresh({
    bool silent = false,
    bool forceShowResult = false,
    bool importAudioDetails = true,
  }) async {
    if (!ref.read(coreRuntimeReadyProvider)) return;
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
    unawaited(
      ref.read(remoteLibraryControllerProvider).syncAllConfiguredInBackground(),
    );
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
    if (!ref.read(coreRuntimeReadyProvider)) return;
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
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _wasSelected = _isSelected;
    final remoteController = ref.read(remoteLibraryControllerProvider);
    _knownRemoteSourceIds = <String>[
      for (final source in remoteController.sources) source.id,
    ];
    _lastObservedSourceId = remoteController.selectedSourceId;
    _activeLibraryIndex = ValueNotifier<int>(
      _resolveLibraryIndex(
        remoteController.selectedSourceId,
        _knownRemoteSourceIds,
      ),
    );
    _renderedLibraryItemCount = _knownRemoteSourceIds.length + 1;
    ref.listenManual<RemoteLibraryController>(
      remoteLibraryControllerProvider,
      (_, next) => _handleRemoteLibraryChanged(next),
    );
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.addListener(_handleActiveTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureStartupRefreshStarted();
    });
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
  }

  @override
  void didUpdateWidget(covariant LibraryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabIndexListenable != widget.activeTabIndexListenable) {
      oldWidget.activeTabIndexListenable?.removeListener(
        _handleActiveTabChanged,
      );
      widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    }
    if (oldWidget.activeSectionListenable != widget.activeSectionListenable) {
      oldWidget.activeSectionListenable?.removeListener(
        _handleActiveTabChanged,
      );
      widget.activeSectionListenable?.addListener(_handleActiveTabChanged);
    }
    _handleActiveTabChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureStartupRefreshStarted();
    }
    _handleStartupRefreshInteractionChanged();
  }

  void _ensureStartupRefreshStarted() {
    if (!_canStartStartupRefresh ||
        _startupRefreshStarted ||
        !ref.read(coreRuntimeReadyProvider)) {
      return;
    }
    _startupRefreshStarted = true;
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
    if (_canStartStartupRefresh &&
        !UiInteractionCoordinator.instance.isInteracting) {
      _scheduleStartupRefreshAfter(const Duration(milliseconds: 500));
    }
  }

  void _scheduleStartupRefreshAfter(Duration quietWindow) {
    _startupRefreshIdleTimer?.cancel();
    _startupRefreshIdleTimer = null;
    if (!_canStartStartupRefresh) return;
    _startupRefreshIdleTimer = Timer(quietWindow, () {
      _startupRefreshIdleTimer = null;
      if (!mounted ||
          !_canStartStartupRefresh ||
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
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _cardSnapshotCommitKey,
      priority: 20,
      structural: true,
      commit: () {
        if (!mounted ||
            !_isActive ||
            _cardSnapshotRequestRevision != structureRevision ||
            libraryFacade.structureRevision != structureRevision) {
          if (_cardSnapshotRequestRevision == structureRevision) {
            _cardSnapshotRequestRevision = null;
          }
          return;
        }
        unawaited(
          libraryFacade
              .ensureCardSnapshot()
              .catchError((Object error, StackTrace stackTrace) {
                AppLogService.error(
                  'library_card_snapshot_failed',
                  error: error,
                  stackTrace: stackTrace,
                );
                return LibraryTreeSnapshot(tree: const [], leafFolderCount: 0);
              })
              .whenComplete(() {
                if (mounted &&
                    _cardSnapshotRequestRevision == structureRevision) {
                  _cardSnapshotRequestRevision = null;
                }
              }),
        );
      },
    );
  }

  @override
  void deactivate() {
    UiInteractionCoordinator.instance.cancelCommit(_cardSnapshotCommitKey);
    _cardSnapshotRequestRevision = null;
    // Sibling disposal can release an interaction before this tab is unmounted.
    UiInteractionCoordinator.instance.removeListener(
      _handleStartupRefreshInteractionChanged,
    );
    _startupRefreshIdleTimer?.cancel();
    _startupRefreshIdleTimer = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (_startupRefreshWaiting) {
      UiInteractionCoordinator.instance.addListener(
        _handleStartupRefreshInteractionChanged,
      );
      _handleStartupRefreshInteractionChanged();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    UiInteractionCoordinator.instance.cancelCommit(_cardSnapshotCommitKey);
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.removeListener(_handleActiveTabChanged);
    UiInteractionCoordinator.instance.removeListener(
      _handleStartupRefreshInteractionChanged,
    );
    _startupRefreshIdleTimer?.cancel();
    disposeTabState();
    _activeLibraryIndex.dispose();
    _localProjectionAvailable.dispose();
    _selectionVersion.dispose();
    _localScrollController.dispose();
    for (final scrollController in _remoteScrollControllers.values) {
      scrollController.dispose();
    }
    _remoteScrollControllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    ref.listen(coreRuntimeReadyProvider, (_, ready) {
      if (ready) _ensureStartupRefreshStarted();
    });
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.pinnedLibraryPaths ?? const <String>[],
      ),
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
    final canPullRefresh = ref.watch(
      libraryListUiProvider.select((s) => s.canPullRefresh),
    );
    final libraryRefreshOperationBusy = ref.watch(
      uiOperationForScopeProvider(
        UiOperationScope.libraryRefresh,
      ).select((s) => s.isBusy),
    );
    UiOperationScope? activeImportScope;
    for (final scope in const <UiOperationScope>[
      UiOperationScope.libraryImportFolder,
      UiOperationScope.libraryImportLibrary,
      UiOperationScope.libraryImportFiles,
    ]) {
      final isScopeBusy = ref.watch(
        uiOperationForScopeProvider(scope).select((s) => s.isBusy),
      );
      if (isScopeBusy) {
        activeImportScope ??= scope;
      }
    }
    final libraryImportBusy = activeImportScope != null;
    final libraryRefreshBusy =
        !ref.watch(coreRuntimeReadyProvider) ||
        libraryRefreshOperationBusy ||
        libraryImportBusy ||
        listStateIsScanning;
    if (_isActive && listStateIsInitialized) {
      _ensureCardSnapshot(
        libraryFacade: libraryFacade,
        snapshotRevision: listStateStructureRevision,
      );
    }
    final bottomInset = MobileOverlayInset.of(context);

    final remoteSources = ref.watch(
      remoteLibraryControllerProvider.select((c) => c.sources),
    );
    final selectedRemoteSource = ref.watch(
      remoteLibraryControllerProvider.select((c) => c.selectedSource),
    );
    _renderedLibraryItemCount = remoteSources.length + 1;
    final topTotalHeight =
        headerHeight + AppPageHeaderMetrics.firstContentSpacing;
    // Remove the extra 96px to make content flush with the bottom dock.
    final listBottomInset = bottomInset;
    final isLandscape =
        widget.isLandscapeLayout ??
        (MediaQuery.orientationOf(context) == Orientation.landscape);
    final listTopPadding = topTotalHeight;
    final listBottomPadding = listBottomInset + 16.0;

    final page = ScrollActivityGate(
      onMetricsChanged: ref.read(libraryCoverUiControllerProvider).viewportChanged,
      child: PageHeaderInset(
        topInset: listTopPadding,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            buildScrollToTopTransition(
              AppFadeThroughIndexedStack.lazy(
                key: const ValueKey<String>('library_source_stack'),
                duration: kAppMotionFast,
                indexListenable: _activeLibraryIndex,
                itemCount: remoteSources.length + 1,
                itemIds: <Object>[
                  _localLibraryStackId,
                  for (final source in remoteSources) source.id,
                ],
                contentRevision: (listTopPadding, listBottomPadding),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildLocalLibraryPane(
                      topPadding: listTopPadding,
                      bottomPadding: listBottomPadding,
                    );
                  }
                  final source = remoteSources[index - 1];
                  return _buildRemoteLibraryPane(
                    source: source,
                    topPadding: listTopPadding,
                    bottomPadding: listBottomPadding,
                  );
                },
              ),
            ),
            // Scan progress card
            Positioned(
              top: listTopPadding + 10,
              left: 12,
              right: 12,
              child: AppDeferredFade(
                visible: listStateIsScanning && !listStateIsBackgroundScanning,
                child: AppPageContentTransition(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final scanState = ref.watch(libraryScanUiProvider);
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
            ),

            // Header — frosted glass overlay on top of the scrolling list
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppHeaderTransition(
                child: _isSelectionMode
                    ? (selectedRemoteSource != null
                          ? Consumer(
                              builder: (context, ref, _) {
                                final settings = ref
                                    .watch(settingsStateProvider)
                                    .value;
                                final removals = ref.watch(
                                  undoableRemovalStateProvider,
                                );
                                final remoteWorks = ref.watch(
                                  remoteLibraryControllerProvider.select(
                                    (c) => c.worksFor(selectedRemoteSource.id),
                                  ),
                                );
                                final visibleRemoteWorks = remoteWorks
                                    .where(
                                      (w) => !removals.isHidden(
                                        remoteWorkRemovalKey(w),
                                      ),
                                    )
                                    .toList(growable: false);
                                final sortedVisible = sortRemoteLibraryWorks(
                                  visibleRemoteWorks,
                                  criterion:
                                      settings?.librarySortCriterion ??
                                      LibrarySortCriterion.name,
                                  ascending:
                                      settings?.librarySortAscending ?? true,
                                );
                                final selectedWorks = sortedVisible
                                    .where(
                                      (w) => _selectedRemoteWorkIds.contains(
                                        w.workId,
                                      ),
                                    )
                                    .toList(growable: false);
                                final allSelected =
                                    sortedVisible.isNotEmpty &&
                                    selectedWorks.length >=
                                        sortedVisible.length;
                                return LibraryBatchSelectionHeader(
                                  keyPrefix: 'library',
                                  i18n: i18n,
                                  selectedCount: selectedWorks.length,
                                  allSelected: allSelected,
                                  onToggleSelectAll: sortedVisible.isEmpty
                                      ? null
                                      : () => _toggleSelectAllRemote(
                                          sortedVisible,
                                        ),
                                  onEditInfo: selectedWorks.length == 1
                                      ? () {
                                          final work = selectedWorks.single;
                                          _exitSelectionMode();
                                          unawaited(
                                            openRemoteWorkDetailEditor(
                                              context,
                                              ref,
                                              work,
                                            ),
                                          );
                                        }
                                      : null,
                                  onAddToPlaylist:
                                      selectedWorks.isEmpty ||
                                          !ref.watch(coreRuntimeReadyProvider)
                                      ? null
                                      : () => addRemoteBatchWorksToPlaylist(
                                          context: context,
                                          ref: ref,
                                          works: selectedWorks,
                                          exitSelectionMode: _exitSelectionMode,
                                        ),
                                  onCompleteMetadata: selectedWorks.isEmpty
                                      ? null
                                      : () {
                                          final ids = selectedWorks
                                              .map((w) => w.workId)
                                              .toSet();
                                          _exitSelectionMode();
                                          unawaited(
                                            Navigator.of(context).push(
                                              buildAppPageRoute<void>(
                                                context: context,
                                                child: DlsiteMetadataBatchPage(
                                                  remoteSourceId:
                                                      selectedRemoteSource.id,
                                                  initialRemoteWorkIds: ids,
                                                  initialScope:
                                                      DlsiteMetadataBatchScope
                                                          .all,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                  onTogglePin: selectedWorks.isEmpty
                                      ? null
                                      : () => toggleRemoteBatchWorksPinned(
                                          context: context,
                                          ref: ref,
                                          sourceId: selectedRemoteSource.id,
                                          workIds: selectedWorks
                                              .map((w) => w.workId)
                                              .toList(growable: false),
                                          exitSelectionMode: _exitSelectionMode,
                                        ),
                                  isPinned:
                                      selectedWorks.isNotEmpty &&
                                      selectedWorks.every((w) => w.isPinned),
                                  onRemove: selectedWorks.isEmpty
                                      ? null
                                      : () => stageRemoteBatchWorksRemoval(
                                          context: context,
                                          ref: ref,
                                          works: selectedWorks,
                                          exitSelectionMode: _exitSelectionMode,
                                        ),
                                  onExit: _exitSelectionMode,
                                );
                              },
                            )
                          : Consumer(
                              builder: (context, ref, _) {
                                final pinnedLibraryPaths = ref
                                    .watch(
                                      settingsStateProvider.select(
                                        (state) =>
                                            state.value?.pinnedLibraryPaths ??
                                            const <String>[],
                                      ),
                                    )
                                    .toSet();
                                final tree = ref.watch(
                                  librarySortedTreeUiProvider,
                                );
                                final selectableCount = tree
                                    .where(isSelectableLibraryNode)
                                    .length;
                                final selectedSelections =
                                    selectedLibraryNodeSelections(
                                      tree,
                                      _selectedLibraryPaths,
                                    );
                                final allSelected =
                                    selectableCount > 0 &&
                                    selectedSelections.length >=
                                        selectableCount;
                                return LibraryBatchSelectionHeader(
                                  keyPrefix: 'library',
                                  i18n: i18n,
                                  selectedCount: selectedSelections.length,
                                  allSelected: allSelected,
                                  onToggleSelectAll: selectableCount == 0
                                      ? null
                                      : () => _toggleSelectAllLibrary(tree),
                                  onEditInfo: selectedSelections.length == 1
                                      ? () {
                                          final target =
                                              selectedSelections.single.target;
                                          _exitSelectionMode();
                                          unawaited(
                                            showAudioDetailEditor(
                                              context,
                                              ref,
                                              target,
                                            ),
                                          );
                                        }
                                      : null,
                                  onAddToPlaylist:
                                      selectedSelections.isEmpty ||
                                          !ref.watch(coreRuntimeReadyProvider)
                                      ? null
                                      : () => addLibraryBatchSelectionsToPlaylist(
                                          context: context,
                                          ref: ref,
                                          selections: selectedSelections,
                                          exitSelectionMode: _exitSelectionMode,
                                        ),
                                  onCompleteMetadata: selectedSelections.isEmpty
                                      ? null
                                      : () =>
                                            completeLibraryBatchSelectionsMetadata(
                                              context: context,
                                              ref: ref,
                                              selections: selectedSelections,
                                              exitSelectionMode:
                                                  _exitSelectionMode,
                                            ),
                                  onTogglePin: selectedSelections.isEmpty
                                      ? null
                                      : () =>
                                            toggleLibraryBatchSelectionsPinned(
                                              context: context,
                                              ref: ref,
                                              selections: selectedSelections,
                                              exitSelectionMode:
                                                  _exitSelectionMode,
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
                                );
                              },
                            ))
                    : Consumer(
                        key: const ValueKey<String>('library_top_header_host'),
                        builder: (context, ref, _) {
                          final libraryHeaderAudioCount = ref.watch(
                            libraryHeaderUiProvider.select((s) => s.audioCount),
                          );
                          final remoteSourceBusy =
                              selectedRemoteSource != null &&
                              ref.watch(
                                remoteLibraryControllerProvider.select(
                                  (c) => c.isLoading(selectedRemoteSource.id),
                                ),
                              );
                          final remoteWorks = selectedRemoteSource == null
                              ? const <RemoteLibraryWork>[]
                              : ref.watch(
                                  remoteLibraryControllerProvider.select(
                                    (c) => c.worksFor(selectedRemoteSource.id),
                                  ),
                                );
                          final removals = ref.watch(
                            undoableRemovalStateProvider,
                          );
                          final visibleRemoteWorks =
                              selectedRemoteSource == null
                              ? const <RemoteLibraryWork>[]
                              : remoteWorks
                                    .where(
                                      (w) => !removals.isHidden(
                                        remoteWorkRemovalKey(w),
                                      ),
                                    )
                                    .toList(growable: false);
                          final remoteTrackTotal = selectedRemoteSource == null
                              ? 0
                              : visibleRemoteWorks.fold<int>(
                                  0,
                                  (sum, w) => sum + w.trackCount,
                                );
                          final headerTitle = selectedRemoteSource == null
                              ? i18n.tr('music_library')
                              : selectedRemoteSource.name;
                          final headerStatsText = selectedRemoteSource == null
                              ? i18n.tr('library_header_stats', {
                                  'works': libraryFacade.libraryCards.length
                                      .toString(),
                                  'sessions': libraryHeaderAudioCount
                                      .toString(),
                                })
                              : (remoteTrackTotal > 0
                                    ? i18n.tr('library_header_stats', {
                                        'works': visibleRemoteWorks.length
                                            .toString(),
                                        'sessions': remoteTrackTotal.toString(),
                                      })
                                    : i18n.tr('asmr_header_stats', {
                                        'count': visibleRemoteWorks.length
                                            .toString(),
                                      }));
                          return TopPageHeader(
                            key: headerKey,
                            icon: selectedRemoteSource == null
                                ? Icons.library_music_rounded
                                : (selectedRemoteSource.isLan
                                      ? Icons.desktop_windows_rounded
                                      : Icons.cloud_outlined),
                            collapseController: _scrollControllerForSourceId(
                              selectedRemoteSource?.id,
                            ),
                            topCapsuleTitle: headerTitle,
                            topCapsuleData: headerStatsText,
                            topRowTrailing: const HeaderFloatingButton(
                              child: LibrarySourceMenuButton(),
                            ),
                            title: headerTitle,
                            titleWidget: _buildHeaderLeftActions(
                              i18n,
                              localImportDisabled:
                                  libraryRefreshBusy ||
                                  selectedRemoteSource != null,
                              batchMetadataDisabled:
                                  selectedRemoteSource != null
                                  ? remoteSourceBusy ||
                                        !selectedRemoteSource.allowEdit
                                  : libraryRefreshBusy,
                            ),
                            trailing: SizedBox(
                              height: 38,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (isLandscape) ...[
                                    HeaderFloatingButton(
                                      child: IconButton(
                                        key: const ValueKey(
                                          'library_refresh_button',
                                        ),
                                        onPressed: selectedRemoteSource != null
                                            ? (remoteSourceBusy
                                                  ? null
                                                  : () => unawaited(
                                                      refreshRemoteSourceWithFeedback(
                                                        context,
                                                        ref,
                                                        selectedRemoteSource.id,
                                                        syncProgress: true,
                                                        showLoadingSnackbar:
                                                            true,
                                                      ),
                                                    ))
                                            : (canPullRefresh &&
                                                      !libraryRefreshBusy
                                                  ? () => unawaited(
                                                      _runLibraryPullRefresh(
                                                        showSnackbar: true,
                                                      ),
                                                    )
                                                  : null),
                                        icon:
                                            (selectedRemoteSource != null
                                                ? remoteSourceBusy
                                                : libraryRefreshBusy)
                                            ? const SizedBox.square(
                                                dimension: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.2,
                                                    ),
                                              )
                                            : const Icon(Icons.refresh_rounded),
                                        tooltip: i18n.tr(
                                          'refresh_watched_folder',
                                        ),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 38,
                                              height: 38,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
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
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 38,
                                            height: 38,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const WorkPageTranslationButton(
                                    buttonKey: 'library_translation',
                                    compact: true,
                                  ),
                                  const SizedBox(width: 8),
                                  HeaderFloatingButton(
                                    child: IconButton(
                                      key: const ValueKey<String>(
                                        'library_sort_button',
                                      ),
                                      onPressed:
                                          (selectedRemoteSource != null
                                              ? remoteSourceBusy
                                              : libraryRefreshBusy)
                                          ? null
                                          : _openSortOptions,
                                      icon: const Icon(Icons.sort_rounded),
                                      tooltip: i18n.tr('sort_by'),
                                      iconSize: 20,
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 38,
                                            height: 38,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
    final content = WorkPageTranslationHost(child: page);
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        _covered = MainTabVisibility.isCovered(context);
        _handleActivityChanged();
        final interceptBack = _isSelectionMode && _isActive;
        return PopScope<void>(
          canPop: !interceptBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _isSelectionMode) {
              _exitSelectionMode();
            }
          },
          child: content,
        );
      },
    );
  }

  Widget _buildLocalLibraryPane({
    required double topPadding,
    required double bottomPadding,
  }) {
    const listCacheExtent = 320.0;
    return BrowsePageScroll(
      pageKey: 'library',
      controller: _localScrollController,
      child: Consumer(
        builder: (context, ref, content) {
          final libraryFacade = ref.read(libraryFacadeProvider);
          final listStateStructureRevision = ref.watch(
            libraryListUiProvider.select((s) => s.structureRevision),
          );
          final listStateIsInitialized = ref.watch(
            libraryListUiProvider.select((s) => s.isInitialized),
          );
          final rawSnapshotReady =
              listStateIsInitialized &&
              listStateStructureRevision == libraryFacade.structureRevision;
          final libraryEmpty = libraryFacade.libraryCards.isEmpty;
          var hasSortedRows = false;
          var sortFailed = false;
          if (_hasWatchedLibrarySort ||
              (rawSnapshotReady &&
                  !libraryEmpty &&
                  TickerMode.valuesOf(context).enabled)) {
            _hasWatchedLibrarySort = true;
            hasSortedRows = ref.watch(
              librarySortedTreeUiProvider.select((nodes) => nodes.isNotEmpty),
            );
            sortFailed = ref.watch(
              librarySortedSnapshotUiProvider.select(
                (snapshot) => snapshot.error != null,
              ),
            );
          }
          final hasSnapshot =
              (rawSnapshotReady && libraryEmpty) || hasSortedRows || sortFailed;
          final listReady = rawSnapshotReady && hasSnapshot;
          return ValueListenableBuilder<bool>(
            valueListenable: _localProjectionAvailable,
            child: content,
            builder: (context, projectionAvailable, paneContent) =>
                AppPageContentTransition.deferred(
                  prepared: listReady,
                  isReady: listReady,
                  // Mount the tree for row preparation under the same
                  // skeleton that covered restoration and sorting.
                  holdPlaceholder:
                      !listStateIsInitialized ||
                      !hasSnapshot ||
                      (hasSortedRows && !projectionAvailable),
                  animatePlaceholder: true,
                  placeholder: LibraryLoadingSkeleton(
                    bottomInset: bottomPadding,
                    topInset: topPadding,
                  ),
                  builder: (_) => paneContent!,
                ),
          );
        },
        child: Consumer(
          builder: (context, ref, _) {
            final i18n = ref.read(appLanguageProviderInstanceProvider);
            final libraryFacade = ref.read(libraryFacadeProvider);
            final listStateStructureRevision = ref.watch(
              libraryListUiProvider.select((s) => s.structureRevision),
            );
            final listStateIsScanning = ref.watch(
              libraryListUiProvider.select((s) => s.isScanning),
            );
            final canPullRefresh = ref.watch(
              libraryListUiProvider.select((s) => s.canPullRefresh),
            );
            final libraryRefreshOperationBusy = ref.watch(
              uiOperationForScopeProvider(
                UiOperationScope.libraryRefresh,
              ).select((s) => s.isBusy),
            );
            UiOperationScope? activeImportScope;
            for (final scope in const <UiOperationScope>[
              UiOperationScope.libraryImportFolder,
              UiOperationScope.libraryImportLibrary,
              UiOperationScope.libraryImportFiles,
            ]) {
              if (ref.watch(
                uiOperationForScopeProvider(scope).select((s) => s.isBusy),
              )) {
                activeImportScope ??= scope;
              }
            }
            final libraryRefreshBusy =
                !ref.watch(coreRuntimeReadyProvider) ||
                libraryRefreshOperationBusy ||
                activeImportScope != null ||
                listStateIsScanning;
            final scrollPhysics = canPullRefresh
                ? AlwaysScrollableScrollPhysics(
                    parent: GlassRefreshIndicatorScrollPhysics(
                      isIndicatorVisible: () =>
                          _refreshIndicatorKey
                              .currentState
                              ?.isIndicatorVisible ??
                          false,
                    ),
                  )
                : null;
            final tree = ref.watch(librarySortedTreeUiProvider);
            final sortingError = ref.watch(
              librarySortedSnapshotUiProvider.select((state) => state.error),
            );
            final emptyBody = sortingError == null
                ? LibraryEmptyState(
                    onImportLibrary: _addLibrary,
                    onImportFolder: _addFolder,
                    onImportFile: _addFiles,
                    isBusy: libraryRefreshBusy,
                    activeImportScope: activeImportScope,
                    bottomInset: bottomPadding,
                    topInset: topPadding,
                    physics: scrollPhysics ?? const ClampingScrollPhysics(),
                  )
                : const SizedBox.expand();
            return Stack(
              children: [
                GlassRefreshIndicator(
                  key: _refreshIndicatorKey,
                  lockChildWhileRefreshing: true,
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  onRefresh: _runLibraryPullRefresh,
                  edgeOffset: topPadding,
                  displacement: 32,
                  triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _selectionVersion,
                    builder: (context, _, _) => PlaceholderContentTransition(
                      key: const ValueKey('library_empty_transition'),
                      showPlaceholder: tree.isEmpty,
                      maintainContent: true,
                      placeholder: emptyBody,
                      content: LibraryTreeList(
                        tree: tree,
                        structureRevision: listStateStructureRevision,
                        selectedPaths: Set<String>.unmodifiable(
                          _selectedLibraryPaths,
                        ),
                        isSelectionMode: _isSelectionMode,
                        scrollController: _localScrollController,
                        i18n: i18n,
                        topPadding: topPadding,
                        bottomPadding: bottomPadding,
                        cacheExtent: listCacheExtent,
                        physics: scrollPhysics,
                        loadFolder: libraryFacade.loadLibraryFolderTree,
                        currentStructureRevision: () =>
                            libraryFacade.structureRevision,
                        onLongPress: _enterSelectionMode,
                        onToggleSelect: _toggleLibrarySelection,
                        onProjectionAvailabilityChanged:
                            _handleProjectionAvailabilityChanged,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: topPadding + 16,
                  left: 12,
                  right: 12,
                  child: AppDeferredFade(
                    visible: sortingError != null,
                    child: OperationStatusBanner(
                      label: i18n.tr('operation_failed_retry'),
                      error: sortingError,
                      retryTooltip: i18n.tr('retry'),
                      onRetry: () =>
                          ref.invalidate(librarySortedSnapshotUiProvider),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildRemoteLibraryPane({
    required RemoteMediaSource source,
    required double topPadding,
    required double bottomPadding,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: _selectionVersion,
      builder: (context, _, _) => RemoteLibraryBrowseView(
        key: ValueKey<String>('remote_view_${source.id}'),
        source: source,
        scrollController: _scrollControllerForRemote(source.id),
        topPadding: topPadding,
        bottomPadding: bottomPadding,
        isSelectionMode: _isSelectionMode,
        selectedWorkIds: Set<String>.unmodifiable(_selectedRemoteWorkIds),
        onEnterSelectionMode: _enterRemoteSelectionMode,
        onToggleSelection: _toggleRemoteSelection,
      ),
    );
  }

  Widget _buildHeaderLeftActions(
    AppLanguageProvider i18n, {
    required bool localImportDisabled,
    required bool batchMetadataDisabled,
  }) {
    return HeaderActionPill(
      children: [
        UnifiedPopupMenuButton<_LibraryAddAction>(
          enabled: !localImportDisabled,
          iconWidget: const BoldAddIcon(),
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
          onPressed: localImportDisabled ? null : _openLibraryManagementPage,
          icon: const LibraryEditIcon(),
          tooltip: i18n.tr('edit_library'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('library_batch_metadata_button'),
          onPressed: batchMetadataDisabled ? null : _openBatchMetadataPage,
          icon: const Icon(Icons.cloud_download_rounded),
          tooltip: i18n.tr('batch_metadata'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
      ],
    );
  }
}
