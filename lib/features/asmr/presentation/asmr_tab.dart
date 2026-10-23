import 'asmr_providers.dart';
import 'asmr_theme.dart';
import '../../library/presentation/library_providers.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import '../../../core/media/search_query_utils.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/widgets/rj_code_overlay.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/page_translation_scope.dart';

import 'asmr_download_page.dart';
import 'asmr_error_text.dart';
import 'asmr_work_detail_sheet.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';

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
  if (controller == null) return const <AsmrWork>[];
  final selected = <AsmrWork>[];
  for (final work in controller.filteredWorksFor(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  )) {
    if (!selectedWorkIds.contains(work.workKey)) continue;
    selected.add(work);
    if (selected.length == selectedWorkIds.length) break;
  }
  return selected;
}

Future<void> _addAsmrWorksToPlaylist({
  required BuildContext context,
  required WidgetRef ref,
  required List<AsmrWork> works,
  required VoidCallback exitSelectionMode,
}) async {
  if (!ref.read(coreRuntimeReadyProvider)) return;
  final playback = ref.read(asmrPlaybackCoordinatorProvider);
  var addedCount = 0;
  if (playback != null) {
    for (final work in works) {
      try {
        await playback.playWork(work, autoPlay: false);
        addedCount += 1;
      } catch (_) {
        // Continue adding the remaining selected works.
      }
    }
  }
  if (!context.mounted) return;
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  exitSelectionMode();
  showAppSnackBar(
    context,
    addedCount > 0
        ? i18n.tr('batch_added_to_playlist', {'count': addedCount.toString()})
        : i18n.tr('operation_failed_retry'),
    tone: addedCount > 0
        ? AppFeedbackTone.success
        : AppFeedbackTone.destructive,
    icon: addedCount > 0
        ? Icons.playlist_add_check_rounded
        : Icons.error_outline_rounded,
    iconColor: AppDesignTokens.of(context).asmrAccent,
  );
}

Future<void> _toggleAsmrWorksFavorite(
  WidgetRef ref,
  List<AsmrWork> works, {
  bool? favorite,
}) async {
  final controller = ref.read(asmrLibraryControllerProvider);
  if (controller == null) return;
  if (favorite == null && works.length == 1) {
    await controller.toggleFavorite(works.single);
    return;
  }
  await controller.setFavorites(
    works,
    favorite: favorite ?? works.any((work) => !work.isFavorite),
  );
}

Future<void> _toggleSelectedAsmrWorksFavorite({
  required BuildContext context,
  required WidgetRef ref,
  required List<AsmrWork> works,
  required VoidCallback refreshSelectionState,
}) async {
  final shouldFavorite = works.any((work) => !work.isFavorite);
  await _toggleAsmrWorksFavorite(ref, works);
  if (!context.mounted) return;
  refreshSelectionState();
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  final accent = AppDesignTokens.of(context).asmrAccent;
  if (!shouldFavorite) {
    showAppSnackBar(
      context,
      i18n.tr('asmr_favorite_removed'),
      actionLabel: i18n.tr('undo'),
      onAction: () =>
          unawaited(_toggleAsmrWorksFavorite(ref, works, favorite: true)),
      duration: const Duration(seconds: 5),
      showCountdown: true,
      showActionCountdown: true,
      tone: AppFeedbackTone.warning,
      icon: Icons.favorite_border_rounded,
      iconColor: accent,
    );
  } else {
    showAppSnackBar(
      context,
      i18n.tr('asmr_favorite_added'),
      tone: AppFeedbackTone.success,
      icon: Icons.favorite_rounded,
      iconColor: accent,
    );
  }
}

Future<void> _downloadAsmrWorks(
  BuildContext context,
  List<AsmrWork> works,
) async {
  for (var i = 0; i < works.length; i++) {
    final work = works[i];
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      buildAppPageRoute<void>(
        context: context,
        child: AsmrDownloadPage(
          work: work,
          batchIndex: works.length > 1 ? i + 1 : null,
          batchTotal: works.length > 1 ? works.length : null,
        ),
      ),
    );
  }
}

class _AsmrBatchSelectionHeader extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final hasUnfavoritedSelection = selectedWorks.any(
      (work) => !work.isFavorite,
    );
    return TopPageHeader(
      key: ValueKey<String>('${keyPrefix}_batch_selection_header'),
      icon: Icons.cloud_rounded,
      iconColor: AppDesignTokens.of(context).asmrAccent,
      topCapsuleTitle: i18n.tr('multi_select'),
      topCapsuleData: i18n.tr('selected_count', {
        'count': selectedWorks.length.toString(),
      }),
      titleWidget: const SizedBox.shrink(),
      leading: HeaderActionPill(
        children: [
          IconButton(
            key: ValueKey<String>('${keyPrefix}_batch_add_button'),
            onPressed: onAddToPlaylist,
            icon: const Icon(Icons.playlist_add_rounded),
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
            onPressed: onToggleFavorite,
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
  bool _categoryContentMounted = false;
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

  AsmrCategoryType get _selectedCategory =>
      _headerCategories[_activeCategoryIndex.value];

  ScrollController get _scrollController =>
      _scrollControllers[_selectedCategory]!;

  bool? _wasActive;
  ModalRoute<dynamic>? _route;

  bool get _isSelected =>
      (widget.activeTabIndexListenable == null ||
          widget.activeTabIndexListenable!.value == tabIndex) &&
      (widget.activeSectionListenable == null ||
          widget.activeSectionListenable!.value == widget.sectionIndex);

  bool get _isActive => (_route?.isCurrent ?? true) && _isSelected;

  @override
  bool get handlesScrollToTop => _isActive;

  @override
  int get tabIndex => widget.tabIndex;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  UiOperationService get _operations => ref.read(uiOperationServiceProvider);

  double _minimumExpandedHeaderHeight(BuildContext context) {
    return AppPageHeaderMetrics.expandedToolbarHeight +
        MediaQuery.paddingOf(context).top;
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
      for (final category in _headerCategories) category: ScrollController(),
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
    final generation = coordinator.generation;
    _activationScheduled = true;
    final accepted = coordinator.scheduleAfterIdle(
      key: 'asmr_tab_activation_${identityHashCode(this)}',
      generation: generation,
      priority: 0,
      task: () async {
        _activationScheduled = false;
        if (!mounted || !_isActive || generation != coordinator.generation) {
          return;
        }
        late final Future<void> task;
        task = _runActivation(
          controller: controller,
          defaultLanguage: defaultLanguage,
          generation: generation,
        );
        _activationTask = task;
        await task;
        if (identical(_activationTask, task)) _activationTask = null;
        if (mounted && _isActive && generation != coordinator.generation) {
          final currentGeneration = coordinator.generation;
          // The idle scheduler releases this task's key after it returns.
          coordinator.scheduleCommit(
            key: _activationCommitKey,
            generation: currentGeneration,
            priority: 0,
            commit: () {
              if (mounted &&
                  _isActive &&
                  currentGeneration == coordinator.generation) {
                _ensureActivated();
              }
            },
          );
        }
      },
    );
    if (!accepted) _activationScheduled = false;
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
        generation: generation,
        priority: 0,
        structural: true,
        commit: () {
          _activationScheduled = false;
          if (!mounted ||
              !_isActive ||
              !identical(controller, ref.read(asmrLibraryControllerProvider))) {
            return;
          }
          if (scope != controller.browseCacheScope) {
            _ensureActivated();
            return;
          }
          setState(() {
            _activeCategoryIndex.value = _restoredCategoryIndex(controller);
            _activationCompleted = true;
          });
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
    if (!_categoryContentMounted) return;
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
    stopScroll();
    if (_isSelectionMode) {
      setState(() {
        _isSelectionMode = false;
        _selectedWorkIds.clear();
      });
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
    setState(() {
      _isSelectionMode = true;
      _selectedWorkIds
        ..clear()
        ..add(work.workKey);
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(() {
      _isSelectionMode = false;
      _selectedWorkIds.clear();
    });
  }

  void _toggleWorkSelection(AsmrWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (!_selectedWorkIds.add(work.workKey)) {
        _selectedWorkIds.remove(work.workKey);
        if (_selectedWorkIds.isEmpty) _isSelectionMode = false;
      }
    });
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
    await _addAsmrWorksToPlaylist(
      context: context,
      ref: ref,
      works: _selectedWorks(),
      exitSelectionMode: _exitSelectionMode,
    );
  }

  Future<void> _toggleSelectedFavorites() async {
    await _toggleSelectedAsmrWorksFavorite(
      context: context,
      ref: ref,
      works: _selectedWorks(),
      refreshSelectionState: () => setState(() {}),
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
      accentColor: AppDesignTokens.of(context).asmrAccent,
    );
  }

  Future<void> _refreshCategoryWithFeedback({bool showSnackbar = false}) async {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
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
        iconColor: asmrBlue,
      );
    }

    await _runCategoryRefresh(_selectedCategory);

    if (!mounted) {
      return;
    }

    if (controller.categoryViewState(_selectedCategory).operationError !=
        null) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_refresh_failed'),
        tone: AppFeedbackTone.warning,
        icon: Icons.sync_problem_rounded,
        iconColor: asmrBlue,
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
      iconColor: asmrBlue,
    );
  }

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: _AsmrSearchPage(initialCategory: _selectedCategory),
        slide: false,
      ),
    );
  }

  Future<T?> _showAsmrPanel<T>({required WidgetBuilder builder}) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return showAppOverlayPanel<T>(
      context: context,
      barrierLabel: i18n.tr('close'),
      themeBuilder: _asmrPanelTheme,
      builder: builder,
    );
  }

  Future<void> _showAccountDialog() {
    return _showAsmrPanel<void>(
      builder: (context) => const _AsmrAccountPanel(),
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_categoryLoadCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_activationCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_languageCommitKey);
    _activeCategoryIndex.dispose();
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
    final headerContentHeight = effectiveHeaderHeight + 4.0;

    final page = PageHeaderInset(
      topInset: headerContentHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppPageContentTransition.deferred(
            prepared:
                _activationCompleted &&
                (ref
                        .read(asmrLibraryControllerProvider)
                        ?.hasLoadedCategory(_selectedCategory) ??
                    false),
            isReady:
                _activationError != null ||
                (globalInitialized && _activationCompleted),
            backgroundColor: Theme.of(context).colorScheme.surface,
            placeholder: LibrarySkeletonListView(
              topInset: headerContentHeight,
              bottomInset: bottomInset + 24,
            ),
            builder: (context) {
              if (_activationCompleted && !_categoryContentMounted) {
                _categoryContentMounted = true;
                // The deferred page protects its opening frame and fade before
                // the restored category starts constructing a remote result.
                _scheduleCategoryLoad();
              }
              return RepaintBoundary(
                child: PlaceholderContentTransition(
                  showPlaceholder:
                      !globalInitialized ||
                      !_activationCompleted ||
                      _activationError != null,
                  placeholder: _activationError == null
                      ? LibrarySkeletonListView(
                          key: const ValueKey('asmr_initial_placeholder'),
                          topInset: headerContentHeight,
                          bottomInset: bottomInset + 24,
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            headerContentHeight,
                            16,
                            bottomInset + 24,
                          ),
                          children: [
                            OperationStatusBanner(
                              label: i18n.tr('operation_failed_retry'),
                              error: _activationError,
                              onRetry: _retryActivation,
                              retryTooltip: i18n.tr('retry'),
                            ),
                          ],
                        ),
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
                      _isSelectionMode,
                      _selectedWorkIds.join(','),
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
                        isSelectionMode: _isSelectionMode,
                        selectedWorkIds: _selectedWorkIds,
                        onEnterSelectionMode: _enterSelectionMode,
                        onToggleSelection: _toggleWorkSelection,
                      );
                    },
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<int>(
              valueListenable: _activeCategoryIndex,
              builder: (context, _, _) => Consumer(
                builder: (context, ref, _) {
                  final categoryState = _activationCompleted
                      ? ref
                            .watch(
                              asmrCategoryStateProvider((
                                category: _selectedCategory,
                                searchQuery: '',
                                searchSession: false,
                              )),
                            )
                            .value
                      : null;
                  final totalWorks = (categoryState?.totalCount ?? 0) > 0
                      ? categoryState!.totalCount
                      : (categoryState?.works.length ?? 0);
                  final asmrStatsText = i18n.tr('asmr_header_stats', {
                    'count': totalWorks.toString(),
                  });
                  final selectedWorks = _isSelectionMode
                      ? _selectedWorks()
                      : const <AsmrWork>[];
                  return Theme(
                    data: asmrThemeData(context),
                    child: AppHeaderTransition(
                      child: _isSelectionMode
                        ? _AsmrBatchSelectionHeader(
                            keyPrefix: 'asmr',
                            i18n: i18n,
                            selectedWorks: selectedWorks,
                            onAddToPlaylist:
                                selectedWorks.isEmpty ||
                                    !ref.watch(coreRuntimeReadyProvider)
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
                            iconColor: AppDesignTokens.of(context).asmrAccent,
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
                                  HeaderFloatingButton(
                                    child: IconButton(
                                      key: const ValueKey<String>(
                                        'asmr_search_button',
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
                                    buttonKey: 'asmr_translation',
                                    compact: true,
                                  ),
                                  if (isLandscape) ...[
                                    const SizedBox(width: 8),
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
                    ),
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
