import 'asmr_providers.dart';
import '../../library/presentation/library_providers.dart';
import '../../library/presentation/library_cover_ui_controller.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/widgets/app_buttons.dart';

import '../../../core/widgets/app_entry_ink_well.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/asmr_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/browse_page_scroll.dart';
import '../application/asmr_download_models.dart';
import '../application/asmr_api_service.dart';
import '../application/asmr_remote_catalog_service.dart';
import '../application/asmr_library_controller.dart';
import '../application/asmr_playback_coordinator.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_edit_panel.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/playlist_icon.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/scroll_to_top_list.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/selection_checkmark.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

import 'asmr_download_page.dart';
import 'asmr_error_text.dart';
import 'asmr_favorite_action.dart';
import 'asmr_work_detail_sheet.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';
import '../../../core/widgets/unified_popup_menu.dart';

part 'asmr_tab_header.dart';
part 'asmr_tab_category_list.dart';
part 'asmr_tab_panel.dart';
part 'asmr_tab_work_tree.dart';
part 'asmr_tab_cover.dart';
part 'asmr_search_page.dart';

class AsmrTab extends ConsumerStatefulWidget {
  const AsmrTab({
    super.key,
    this.tabIndex = 0,
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
  ConsumerState<AsmrTab> createState() => _AsmrTabState();
}

List<AsmrWork> _selectedAsmrWorks(
  WidgetRef ref, {
  required AsmrCategoryType category,
  required String searchQuery,
  bool searchSession = false,
  required Set<String> selectedWorkIds,
}) {
  if (selectedWorkIds.isEmpty) return const <AsmrWork>[];
  final controller = ref.read(asmrLibraryControllerProvider);
  return controller?.selectedWorks(
        category,
        searchQuery: searchQuery,
        searchSession: searchSession,
        workIds: selectedWorkIds,
      ) ??
      const <AsmrWork>[];
}

const _asmrBatchAddScope = UiOperationScope('asmr:batch-add');

Future<void> _addAsmrWorksToPlaylist({
  required BuildContext context,
  required WidgetRef ref,
  required List<AsmrWork> works,
  void Function(Set<String> failedIds)? onFinished,
}) async {
  if (!ref.read(coreRuntimeReadyProvider) || works.isEmpty) return;
  final operations = ref.read(uiOperationServiceProvider);
  if (operations.isBusy(_asmrBatchAddScope)) return;
  final playback = ref.read(asmrPlaybackCoordinatorProvider);
  if (playback == null) return;
  final failedIds = <String>{};
  await operations.run<void>(
    scope: _asmrBatchAddScope,
    labelKey: 'loading_dot',
    cancelPrevious: false,
    task: (_) async {
      for (final work in works) {
        try {
          await playback.playWork(work, autoPlay: false);
        } catch (_) {
          failedIds.add(work.workKey);
        }
      }
    },
  );
  if (!context.mounted) return;
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  onFinished?.call(failedIds);
  showAppSnackBar(
    context,
    failedIds.isEmpty
        ? i18n.tr('batch_added_to_playlist', {'count': works.length.toString()})
        : onFinished == null
        ? i18n.tr('operation_failed_retry')
        : i18n.tr('batch_added_to_playlist_result', {
            'success': works.length - failedIds.length,
            'failed': failedIds.length,
          }),
    tone: failedIds.isEmpty ? AppFeedbackTone.success : AppFeedbackTone.warning,
    icon: failedIds.isEmpty
        ? Icons.playlist_add_check_rounded
        : Icons.error_outline_rounded,
    iconColor: Theme.of(context).colorScheme.primary,
  );
}

Future<void> _toggleSelectedAsmrWorksFavorite({
  required BuildContext context,
  required WidgetRef ref,
  required List<AsmrWork> works,
  required VoidCallback refreshSelectionState,
}) async {
  final changed = await setAsmrWorksFavoriteWithFeedback(context, ref, works);
  if (context.mounted && changed) refreshSelectionState();
}

Future<void> _downloadAsmrWorks(
  BuildContext context,
  List<AsmrWork> works,
) async {
  for (var i = 0; i < works.length; i++) {
    final work = works[i];
    if (!context.mounted) return;
    final result = await Navigator.of(context).push<AsmrDownloadPageResult>(
      buildAppPageRoute<AsmrDownloadPageResult>(
        context: context,
        child: AsmrDownloadPage(
          work: work,
          batchIndex: works.length > 1 ? i + 1 : null,
          batchTotal: works.length > 1 ? works.length : null,
        ),
      ),
    );
    if (result != AsmrDownloadPageResult.added &&
        result != AsmrDownloadPageResult.skipped) {
      return;
    }
  }
}

class _AsmrBatchSelectionHeader extends ConsumerWidget {
  const _AsmrBatchSelectionHeader({
    required this.keyPrefix,
    required this.i18n,
    required this.selectedWorks,
    required this.onAddToPlaylist,
    required this.onDownload,
    required this.onToggleFavorite,
    required this.onExit,
  });

  final String keyPrefix;
  final AppLanguageProvider i18n;
  final List<AsmrWork> selectedWorks;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onDownload;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adding = ref
        .watch(uiOperationForScopeProvider(_asmrBatchAddScope))
        .isBusy;
    final favoriting = selectedWorks.any(
      (work) => ref
          .watch(
            uiOperationForScopeProvider(
              UiOperationScope.asmrWork(
                AsmrOperationKind.favorite,
                work.workKey,
              ),
            ),
          )
          .isBusy,
    );
    final hasUnfavoritedSelection = selectedWorks.any(
      (work) => !work.isFavorite,
    );
    return TopPageHeader(
      key: ValueKey<String>('${keyPrefix}_batch_selection_header'),
      icon: Icons.cloud_rounded,
      iconColor: Theme.of(context).colorScheme.primary,
      topCapsuleTitle: i18n.tr('multi_select'),
      topCapsuleData: i18n.tr('selected_count'),
      topCapsuleDataCount: selectedWorks.length,
      titleWidget: const SizedBox.shrink(),
      leading: HeaderActionPill(
        shrinkSpacingToFit: true,
        children: [
          IconButton(
            key: ValueKey<String>('${keyPrefix}_batch_add_button'),
            onPressed: adding ? null : onAddToPlaylist,
            icon: const PlaylistIcon.add(),
            tooltip: i18n.tr('batch_add_to_playlist'),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: HeaderActionPill.buttonConstraints,
          ),
          IconButton(
            key: ValueKey<String>('${keyPrefix}_batch_download_button'),
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded),
            tooltip: i18n.tr('batch_download'),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: HeaderActionPill.buttonConstraints,
          ),
          IconButton(
            key: ValueKey<String>('${keyPrefix}_batch_favorite_button'),
            onPressed: favoriting ? null : onToggleFavorite,
            icon: Icon(
              hasUnfavoritedSelection
                  ? Icons.favorite_border_rounded
                  : Icons.favorite_rounded,
            ),
            tooltip: i18n.tr(
              hasUnfavoritedSelection ? 'batch_favorite' : 'batch_unfavorite',
            ),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: HeaderActionPill.buttonConstraints,
          ),
        ],
      ),
      trailing: HeaderFloatingButton(
        child: IconButton(
          key: ValueKey<String>('${keyPrefix}_exit_selection_button'),
          onPressed: onExit,
          icon: const Icon(Icons.close_rounded),
          tooltip: i18n.tr('cancel'),
        ),
      ),
    );
  }
}

class _AsmrTabState extends ConsumerState<AsmrTab>
    with MainTabStateMixin<AsmrTab> {
  static const _headerCategories = <AsmrCategoryType>[
    AsmrCategoryType.collected,
    AsmrCategoryType.recommendation,
    AsmrCategoryType.favorites,
    AsmrCategoryType.history,
  ];

  late final ValueNotifier<int> _activeCategoryIndex;
  late final Map<AsmrCategoryType, ScrollController> _scrollControllers;
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  double? _lastHeaderMeasureWidth;
  double? _lastHeaderMeasureTopPadding;
  double? _lastHeaderMeasureTextScale;
  AppLanguage? _lastHeaderMeasureLanguage;
  bool _headerMeasurementScheduled = false;
  bool _forceHeaderMeasurement = false;
  AppLanguage? _pendingPageLanguageSync;
  Future<void>? _activationTask;
  Object? _activationError;
  bool _activationCompleted = false;
  bool _activationScheduled = false;
  bool _accountHydrationScheduled = false;
  bool _accountHydrationRunning = false;
  bool _accountHydrationCompleted = false;
  late final String _categoryLoadCommitKey =
      'asmr_category_load_${identityHashCode(this)}';
  late final String _activationCommitKey =
      'asmr_activation_${identityHashCode(this)}';
  late final String _languageCommitKey =
      'asmr_page_language_${identityHashCode(this)}';
  late final AppLanguageProvider _languageProvider;
  bool _isSelectionMode = false;
  final Set<String> _selectedWorkIds = <String>{};
  final ValueNotifier<({bool active, Set<String> ids})> _selectionListenable =
      ValueNotifier((active: false, ids: const <String>{}));

  void _syncSelectionListenable() {
    _selectionListenable.value = (
      active: _isSelectionMode,
      ids: Set<String>.unmodifiable(_selectedWorkIds),
    );
  }

  AsmrCategoryType get _selectedCategory =>
      _headerCategories[_activeCategoryIndex.value];

  ScrollController get _scrollController =>
      _scrollControllers[_selectedCategory]!;

  bool? _wasActive;
  ModalRoute<dynamic>? _route;
  bool _covered = false;

  bool get _isSelected =>
      (widget.activeTabIndexListenable == null ||
          widget.activeTabIndexListenable!.value == tabIndex) &&
      (widget.activeSectionListenable == null ||
          widget.activeSectionListenable!.value == widget.sectionIndex);

  bool get _isActive =>
      !_covered && (_route?.isCurrent ?? true) && _isSelected;

  @override
  bool get handlesScrollToTop => _isActive;

  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollController;

  UiOperationService get _operations => ref.read(uiOperationServiceProvider);

  double _minimumExpandedHeaderHeight(BuildContext context) {
    return AppPageHeaderMetrics.headerHeight(
      context,
      additionalHeight: 6 + AppPageHeaderMetrics.buttonSize,
    );
  }

  Future<T> _runAsmrOperation<T>({
    required UiOperationScope scope,
    required String labelKey,
    required Future<T> Function() task,
  }) {
    return _operations.run<T>(
      scope: scope,
      labelKey: labelKey,
      task: (_) => task(),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollControllers = {
      for (final category in _headerCategories)
        category: WindowsSmoothScrollController(),
    };
    _activeCategoryIndex = ValueNotifier<int>(0);
    _languageProvider = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller?.initialized == true &&
        controller!.pageLanguage == _languageProvider.language) {
      _activeCategoryIndex.value = _restoredCategoryIndex(controller);
      _activationCompleted = controller.hasLoadedCategory(_selectedCategory);
    }
    _languageProvider.addListener(_handleAppLanguageChanged);
    widget.activeTabIndexListenable?.addListener(_handleActivityChanged);
    widget.activeSectionListenable?.addListener(_handleActivityChanged);
    final mainController = ref.read(mainScreenControllerProvider);
    initTabState(mainController.scrollToTopTab, mainController.stopScrollTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isActive) return;
      _scheduleHeaderMeasurement(force: true);
      if (_activationCompleted) _scheduleCategoryLoad();
    });
  }

  void _handleActivityChanged() {
    if (!mounted) return;
    final active = _isActive;
    if (active == _wasActive) return;
    _wasActive = active;
    if (!active) {
      UiInteractionCoordinator.instance.cancelCommit(_categoryLoadCommitKey);
      UiInteractionCoordinator.instance.cancelCommit(_activationCommitKey);
      UiInteractionCoordinator.instance.cancelCommit(_languageCommitKey);
      _pendingPageLanguageSync = null;
      _activationScheduled = false;
      _accountHydrationScheduled = false;
      return;
    }
    _scheduleHeaderMeasurement();
    _ensureActivated();
  }

  void _ensureActivated() {
    if (!_isActive || _activationError != null) return;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final coordinator = UiInteractionCoordinator.instance;
    if (_activationCompleted) {
      _scheduleCategoryLoad();
      _scheduleAccountHydration(controller, coordinator.generation);
      return;
    }
    if (_activationTask != null || _activationScheduled) {
      return;
    }
    final defaultLanguage = AsmrContentLanguage.fromAppLanguageName(
      ref.read(appLanguageProviderInstanceProvider).language.name,
    );
    _activationScheduled = true;
    // Gate the start on interaction without holding or waiting for a slot
    // shared with startup work such as download and history restoration.
    coordinator.scheduleCommit(
      key: _activationCommitKey,
      priority: 0,
      commit: () {
        _activationScheduled = false;
        if (!mounted ||
            !_isActive ||
            !identical(controller, ref.read(asmrLibraryControllerProvider))) {
          return;
        }
        final generation = coordinator.generation;
        final task = _runActivation(
          controller: controller,
          defaultLanguage: defaultLanguage,
          generation: generation,
        );
        _activationTask = task;
        unawaited(
          task.whenComplete(() {
            if (identical(_activationTask, task)) _activationTask = null;
            if (mounted && _isActive && generation != coordinator.generation) {
              _ensureActivated();
            }
          }),
        );
      },
    );
  }

  Future<void> _runActivation({
    required AsmrLibraryController controller,
    required AsmrContentLanguage defaultLanguage,
    required int generation,
  }) async {
    try {
      await controller.initializeForVisiblePage(
        defaultLanguage: defaultLanguage,
      );
      final scope = controller.browseCacheScope;
      final coordinator = UiInteractionCoordinator.instance;
      if (!mounted ||
          !_isActive ||
          generation != coordinator.generation ||
          !identical(controller, ref.read(asmrLibraryControllerProvider))) {
        return;
      }
      _activationScheduled = true;
      coordinator.scheduleCommit(
        key: _activationCommitKey,
        priority: 0,
        structural: true,
        commit: () {
          _activationScheduled = false;
          if (!mounted ||
              !_isActive ||
              !identical(controller, ref.read(asmrLibraryControllerProvider))) {
            return;
          }
          if (generation != coordinator.generation ||
              scope != controller.browseCacheScope) {
            _ensureActivated();
            return;
          }
          setState(() {
            _activeCategoryIndex.value = _restoredCategoryIndex(controller);
            _activationCompleted = true;
          });
          _scheduleCategoryLoad();
          _scheduleAccountHydration(controller, coordinator.generation);
        },
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_visible_activation_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted &&
          _isActive &&
          generation == UiInteractionCoordinator.instance.generation &&
          identical(controller, ref.read(asmrLibraryControllerProvider))) {
        setState(() => _activationError = error);
      }
    }
  }

  int _restoredCategoryIndex(AsmrLibraryController controller) {
    final savedCategory = ref
        .read(browsePageStateStoreProvider)
        .stateFor('asmr_root:${controller.browseCacheScope}')['category'];
    final index = _headerCategories.indexWhere(
      (category) => category.name == savedCategory,
    );
    return index < 0 ? 0 : index;
  }

  void _retryActivation() {
    setState(() => _activationError = null);
    _ensureActivated();
  }

  void _scheduleAccountHydration(
    AsmrLibraryController controller,
    int generation,
  ) {
    if (_accountHydrationCompleted ||
        _accountHydrationScheduled ||
        _accountHydrationRunning ||
        !mounted ||
        !_isActive) {
      return;
    }
    final coordinator = UiInteractionCoordinator.instance;
    _accountHydrationScheduled = true;
    final accepted = coordinator.scheduleAfterIdle(
      key: 'asmr_account_hydration_${identityHashCode(this)}',
      generation: generation,
      priority: 90,
      task: () async {
        _accountHydrationScheduled = false;
        if (!mounted || !_isActive || generation != coordinator.generation) {
          return;
        }
        // Only gate the start on idle. Network pagination must not hold the
        // shared scheduler slot needed by other pages' local queries.
        unawaited(_hydrateAccount(controller));
      },
    );
    if (!accepted) _accountHydrationScheduled = false;
  }

  Future<void> _hydrateAccount(AsmrLibraryController controller) async {
    _accountHydrationRunning = true;
    try {
      await controller.restoreAsmrAccountSession();
      if (controller.isAsmrAccountLoggedIn) {
        await controller.syncAsmrAccount();
      }
      if (mounted) _accountHydrationCompleted = true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_account_hydration_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _accountHydrationRunning = false;
    }
  }

  @override
  void didUpdateWidget(covariant AsmrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabIndexListenable != widget.activeTabIndexListenable) {
      oldWidget.activeTabIndexListenable?.removeListener(
        _handleActivityChanged,
      );
      widget.activeTabIndexListenable?.addListener(_handleActivityChanged);
    }
    if (oldWidget.activeSectionListenable != widget.activeSectionListenable) {
      oldWidget.activeSectionListenable?.removeListener(_handleActivityChanged);
      widget.activeSectionListenable?.addListener(_handleActivityChanged);
    }
    _handleActivityChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mediaQuery = MediaQuery.of(context);
    final width = mediaQuery.size.width;
    final topPadding = mediaQuery.padding.top;
    final textScale = mediaQuery.textScaler.scale(1);
    final metricsChanged =
        _lastHeaderMeasureWidth == null ||
        (width - _lastHeaderMeasureWidth!).abs() > 0.5 ||
        (topPadding - _lastHeaderMeasureTopPadding!).abs() > 0.5 ||
        (textScale - _lastHeaderMeasureTextScale!).abs() > 0.01;
    _lastHeaderMeasureWidth = width;
    _lastHeaderMeasureTopPadding = topPadding;
    _lastHeaderMeasureTextScale = textScale;
    if (metricsChanged) {
      _scheduleHeaderMeasurement(force: true);
    }
    // A covered route can finish initialization before this page is current.
    // Resume its activation on return without restarting an in-flight task.
    if (!_activationCompleted) _ensureActivated();
  }

  void _scheduleHeaderMeasurement({bool force = false}) {
    _forceHeaderMeasurement = _forceHeaderMeasurement || force;
    if (_headerMeasurementScheduled || !_isActive) return;
    _headerMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerMeasurementScheduled = false;
      final forceMeasurement = _forceHeaderMeasurement;
      _forceHeaderMeasurement = false;
      if (!mounted || !_isActive) return;
      _measureHeader(force: forceMeasurement);
    });
  }

  void _measureHeader({bool force = false}) {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final measuredHeight = box.size.height;
      final minimumExpandedHeight = _minimumExpandedHeaderHeight(context);
      final h = measuredHeight < minimumExpandedHeight
          ? minimumExpandedHeight
          : measuredHeight;
      if (h > 0 &&
          (force || _headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
        setState(() => _headerHeight = h);
      }
    }
  }

  Future<void> _ensureCategoryLoaded(AsmrCategoryType category) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    await controller.ensureCategoryLoaded(category);
  }

  void _scheduleCategoryLoad() {
    if (!_activationCompleted) return;
    final category = _selectedCategory;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _categoryLoadCommitKey,
      commit: () {
        if (!mounted || !_isActive || category != _selectedCategory) return;
        unawaited(_ensureCategoryLoaded(category));
      },
    );
  }

  Future<void> _runCategoryRefresh(AsmrCategoryType category) {
    return _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: () =>
          ref.read(asmrLibraryControllerProvider)?.refreshCategory(category) ??
          Future<void>.value(),
    );
  }

  void _selectCategory(AsmrCategoryType category) {
    if (_selectedCategory == category) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    stopScroll();
    if (_isSelectionMode) {
      _isSelectionMode = false;
      _selectedWorkIds.clear();
      _syncSelectionListenable();
    }
    final targetIndex = _headerCategories.indexOf(category);
    if (targetIndex >= 0) {
      _activeCategoryIndex.value = targetIndex;
    }
    final scope =
        ref.read(asmrLibraryControllerProvider)?.browseCacheScope ?? '';
    ref.read(browsePageStateStoreProvider).update('asmr_root:$scope', {
      'category': category.name,
    });
    _scheduleCategoryLoad();
  }

  void _enterSelectionMode(AsmrWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    _isSelectionMode = true;
    _selectedWorkIds
      ..clear()
      ..add(work.workKey);
    _syncSelectionListenable();
  }

  void _exitSelectionMode() {
    _isSelectionMode = false;
    _selectedWorkIds.clear();
    _syncSelectionListenable();
  }

  void _toggleWorkSelection(AsmrWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    if (!_selectedWorkIds.add(work.workKey)) {
      _selectedWorkIds.remove(work.workKey);
      if (_selectedWorkIds.isEmpty) _isSelectionMode = false;
    }
    _syncSelectionListenable();
  }

  List<AsmrWork> _selectedWorks() {
    return _selectedAsmrWorks(
      ref,
      category: _selectedCategory,
      searchQuery: '',
      selectedWorkIds: _selectedWorkIds,
    );
  }

  Future<void> _addSelectedWorksToPlaylist() async {
    final works = _selectedWorks();
    if (works.isNotEmpty) {
      unawaited(
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
      );
    }
    await _addAsmrWorksToPlaylist(
      context: context,
      ref: ref,
      works: works,
      onFinished: (failedIds) {
        _selectedWorkIds
          ..clear()
          ..addAll(failedIds);
        _isSelectionMode = failedIds.isNotEmpty;
        _syncSelectionListenable();
      },
    );
  }

  Future<void> _toggleSelectedFavorites() async {
    final works = _selectedWorks();
    if (works.isNotEmpty) {
      unawaited(
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
      );
    }
    await _toggleSelectedAsmrWorksFavorite(
      context: context,
      ref: ref,
      works: works,
      refreshSelectionState: _syncSelectionListenable,
    );
  }

  Future<void> _downloadSelectedWorks() async {
    final works = _selectedWorks();
    _exitSelectionMode();
    await _downloadAsmrWorks(context, works);
  }

  Widget _buildCategorySwitcher(AppLanguageProvider i18n) {
    return HeaderSegmentedCategoryBar<AsmrCategoryType>(
      items: _headerCategories,
      selected: _selectedCategory,
      onSelected: _selectCategory,
      labelBuilder: (category) => i18n.tr(_asmrCategoryLabelKey(category)),
      accentColor: Theme.of(context).colorScheme.primary,
    );
  }

  Future<void> _refreshCategoryWithFeedback({bool showSnackbar = false}) async {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final beforeIds = controller
        .filteredWorksFor(_selectedCategory)
        .map((work) => work.workKey)
        .toList(growable: false);

    if (showSnackbar) {
      showAppSnackBar(
        context,
        i18n.tr('loading_dot'),
        icon: Icons.sync_rounded,
        iconColor: primaryColor,
      );
    }

    await _runCategoryRefresh(_selectedCategory);

    if (!mounted) {
      return;
    }

    final refreshError = controller
        .categoryViewState(_selectedCategory)
        .operationError;
    if (refreshError != null) {
      showAppSnackBar(
        context,
        localizedAsmrCatalogErrorText(i18n, refreshError),
        tone: AppFeedbackTone.warning,
        icon: Icons.sync_problem_rounded,
        iconColor: primaryColor,
      );
      return;
    }

    final afterIds = controller
        .filteredWorksFor(_selectedCategory)
        .map((work) => work.workKey)
        .toList(growable: false);
    final hasUpdates = !listEquals(beforeIds, afterIds);
    showAppSnackBar(
      context,
      i18n.tr(
        hasUpdates ? 'asmr_refresh_done_updated' : 'asmr_refresh_no_updates',
      ),
      tone: hasUpdates ? AppFeedbackTone.success : AppFeedbackTone.info,
      icon: hasUpdates
          ? Icons.sync_rounded
          : Icons.check_circle_outline_rounded,
      iconColor: primaryColor,
    );
  }

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppSearchPageRoute(
        context: context,
        child: AsmrSearchPage(initialCategory: _selectedCategory),
      ),
    );
  }

  Future<T?> _showAsmrPanel<T>({required WidgetBuilder builder}) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return showAppOverlayPanel<T>(
      context: context,
      barrierLabel: i18n.tr('close'),
      builder: builder,
    );
  }

  Future<void> _showAccountDialog() {
    return _showAsmrPanel<void>(
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height - 96).clamp(
            280.0,
            560.0,
          ),
        ),
        child: const AppEditPanelSurface(
          surfaceKey: ValueKey('asmr_panel_surface'),
          child: _AsmrAccountPanel(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_categoryLoadCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_activationCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_languageCommitKey);
    _activeCategoryIndex.dispose();
    _selectionListenable.dispose();
    _languageProvider.removeListener(_handleAppLanguageChanged);
    widget.activeTabIndexListenable?.removeListener(_handleActivityChanged);
    widget.activeSectionListenable?.removeListener(_handleActivityChanged);
    disposeTabState();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(asmrLibraryControllerProvider);
    final globalInitialized = ref.watch(
      asmrLibraryGlobalStateProvider.select(
        (state) => state.value?.initialized ?? controller?.initialized ?? false,
      ),
    );
    final hasDownloadManager = ref.watch(asmrDownloadManagerProvider) != null;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (_lastHeaderMeasureLanguage != i18n.language) {
      _lastHeaderMeasureLanguage = i18n.language;
      _scheduleHeaderMeasurement(force: true);
    }
    _schedulePageLanguageSync(i18n.language);
    final isLandscape =
        widget.isLandscapeLayout ??
        (MediaQuery.orientationOf(context) == Orientation.landscape);
    final bottomInset = MobileOverlayInset.of(context);
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : _minimumExpandedHeaderHeight(context);
    final headerContentHeight =
        effectiveHeaderHeight + AppPageHeaderMetrics.firstContentSpacing;

    final page = PageHeaderInset(
      topInset: headerContentHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          buildScrollToTopTransition(
            ListenableBuilder(
              listenable: _activeCategoryIndex,
              builder: (context, child) => Consumer(
                builder: (context, ref, _) {
                  final category = _selectedCategory;
                  final activationReady =
                      globalInitialized && _activationCompleted;
                  final prepared =
                      activationReady &&
                      (ref
                              .read(asmrLibraryControllerProvider)
                              ?.hasLoadedCategory(category) ??
                          false);
                  final categoryReady =
                      activationReady &&
                      ref.watch(
                        asmrCategoryStateProvider((
                          category: category,
                          searchQuery: '',
                          searchSession: false,
                        )).select((result) {
                          final state = result.value;
                          return state != null &&
                              state.hasAttemptedLoad &&
                              !state.isLoading;
                        }),
                      );
                  // Keep the opening skeleton while the category would draw
                  // another one. Crossfading the two reveals the background.
                  return AppPageContentTransition.deferred(
                    prepared: prepared,
                    isReady:
                        _activationError != null || prepared || categoryReady,
                    animatePlaceholder: true,
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    placeholder: LibrarySkeletonListView(
                      topInset: headerContentHeight,
                      bottomInset: bottomInset + 16,
                    ),
                    builder: (_) => child!,
                  );
                },
              ),
              child: RepaintBoundary(
                child: PlaceholderContentTransition(
                  showPlaceholder:
                      !globalInitialized ||
                      !_activationCompleted ||
                      _activationError != null,
                  placeholder: _activationError == null
                      ? LibrarySkeletonListView(
                          key: const ValueKey('asmr_initial_placeholder'),
                          topInset: headerContentHeight,
                          bottomInset: bottomInset + 16,
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            headerContentHeight,
                            16,
                            bottomInset + 16,
                          ),
                          children: [
                            OperationStatusBanner(
                              label: localizedAsmrCatalogErrorText(
                                i18n,
                                _activationError,
                              ),
                              error: _activationError,
                              onRetry: _retryActivation,
                              retryTooltip: i18n.tr('retry'),
                            ),
                          ],
                        ).withWindowsSmoothScroll(),
                  content: AppFadeThroughIndexedStack.lazy(
                    key: const ValueKey<String>('asmr_category_stack'),
                    indexListenable: _activeCategoryIndex,
                    itemCount: _headerCategories.length,
                    // Retained categories need new widgets only when their
                    // constructor inputs change, not for unrelated tab rebuilds.
                    contentRevision: (
                      !_activationCompleted,
                      headerContentHeight,
                      bottomInset,
                    ),
                    itemBuilder: (context, index) {
                      final category = _headerCategories[index];
                      return _AsmrCategoryList(
                        key: ValueKey(category),
                        isActive: () => category == _selectedCategory,
                        isPageActive: () => _isActive,
                        category: category,
                        isLoadPending: !_activationCompleted,
                        scrollController: _scrollControllers[category]!,
                        searchQuery: '',
                        topInset: headerContentHeight,
                        bottomInset: bottomInset,
                        onRefresh: _refreshCategoryWithFeedback,
                        selectionListenable: _selectionListenable,
                        onEnterSelectionMode: _enterSelectionMode,
                        onToggleSelection: _toggleWorkSelection,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<int>(
              valueListenable: _activeCategoryIndex,
              builder: (context, _, _) => Consumer(
                builder: (context, ref, _) {
                  final stats = _activationCompleted
                      ? ref.watch(
                          asmrCategoryStateProvider((
                            category: _selectedCategory,
                            searchQuery: '',
                            searchSession: false,
                          )).select((async) {
                            final state = async.value;
                            if (state == null) return null;
                            return (
                              totalCount: state.totalCount,
                              worksLength: state.works.length,
                              hasCombinedTotalCount: state.hasCombinedTotalCount,
                              isPartialError:
                                  state.lastError
                                      is AsmrPartialCatalogException,
                            );
                          }),
                        )
                      : null;
                  final totalWorks = (stats?.totalCount ?? 0) > 0
                      ? stats!.totalCount
                      : (stats?.worksLength ?? 0);
                  var statsKey = 'asmr_header_stats';
                  if (stats?.hasCombinedTotalCount == true) {
                    statsKey = 'asmr_header_stats_combined';
                  } else if (stats?.isPartialError == true) {
                    statsKey = 'asmr_header_stats_loaded';
                  }
                  final asmrStatsText = i18n.tr(statsKey, {
                    'count': totalWorks.toString(),
                  });
                  final coreRuntimeReady = ref.watch(coreRuntimeReadyProvider);
                  return ValueListenableBuilder<({bool active, Set<String> ids})>(
                    valueListenable: _selectionListenable,
                    builder: (context, selection, _) {
                      final selectedWorks = selection.active
                          ? _selectedWorks()
                          : const <AsmrWork>[];
                      return AppHeaderTransition(
                        child: selection.active
                            ? _AsmrBatchSelectionHeader(
                                keyPrefix: 'asmr',
                                i18n: i18n,
                                selectedWorks: selectedWorks,
                                onAddToPlaylist:
                                    selectedWorks.isEmpty || !coreRuntimeReady
                                    ? null
                                    : _addSelectedWorksToPlaylist,
                                onDownload: selectedWorks.isEmpty
                                    ? null
                                    : _downloadSelectedWorks,
                                onToggleFavorite: selectedWorks.isEmpty
                                    ? null
                                    : _toggleSelectedFavorites,
                                onExit: _exitSelectionMode,
                              )
                            : TopPageHeader(
                            key: _headerKey,
                            icon: Icons.cloud_rounded,
                            iconColor: Theme.of(context).colorScheme.primary,
                            collapseController: _scrollController,
                            topCapsuleTitle: i18n.tr('online_audio_library'),
                            topCapsuleData: asmrStatsText,
                            title: i18n.tr('online_audio_library'),
                            titleWidget: _buildCategorySwitcher(i18n),
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
                                          'asmr_refresh_button',
                                        ),
                                        onPressed: globalInitialized
                                            ? () => unawaited(
                                                _refreshCategoryWithFeedback(
                                                  showSnackbar: true,
                                                ),
                                              )
                                            : null,
                                        icon: const Icon(Icons.refresh_rounded),
                                        tooltip: i18n.tr('refresh'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  HeaderFloatingButton(
                                    child: IconButton(
                                      key: const ValueKey<String>(
                                        'asmr_search_button',
                                      ),
                                      onPressed: _openSearchPage,
                                      icon: const Icon(Icons.search_rounded),
                                      tooltip: i18n.tr('search'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const WorkPageTranslationButton(
                                    buttonKey: 'asmr_translation',
                                    compact: true,
                                  ),
                                  if (hasDownloadManager)
                                    const _AsmrDownloadProgressInlineButton(),
                                  const SizedBox(width: 8),
                                  HeaderFloatingButton(
                                    child: _AsmrAccountButton(
                                      onPressed: _showAccountDialog,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
    final content = WorkPageTranslationHost(child: page);
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        _covered = MainTabVisibility.isCovered(context);
        _handleActivityChanged();
        return content;
      },
    );
  }

  void _schedulePageLanguageSync(AppLanguage language) {
    if (!_isActive) return;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null || !controller.initialized) return;
    if (controller.pageLanguage == language) {
      _pendingPageLanguageSync = null;
      UiInteractionCoordinator.instance.cancelCommit(_languageCommitKey);
      return;
    }
    if (_pendingPageLanguageSync == language) {
      return;
    }
    _pendingPageLanguageSync = language;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _languageCommitKey,
      priority: 0,
      commit: () {
        if (!mounted || _pendingPageLanguageSync != language) return;
        _pendingPageLanguageSync = null;
        if (!_isActive || _languageProvider.language != language) return;
        if (controller.setPageLanguage(language)) _scheduleCategoryLoad();
      },
    );
  }

  void _handleAppLanguageChanged() {
    if (!mounted) return;
    _schedulePageLanguageSync(_languageProvider.language);
  }
}
