import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../app/localization/app_language_provider.dart';
import '../domain/asmr_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../application/asmr_download_models.dart';
import '../application/asmr_api_service.dart';
import '../application/asmr_library_controller.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_scroll_physics.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';

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
  ConsumerState<AsmrTab> createState() => _AsmrTabState();
}

class _AsmrTabState extends ConsumerState<AsmrTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<AsmrTab> {
  static const _headerCategories = <AsmrCategoryType>[
    AsmrCategoryType.collected,
    AsmrCategoryType.recommendation,
    AsmrCategoryType.favorites,
    AsmrCategoryType.history,
  ];

  AsmrCategoryType _selectedCategory = AsmrCategoryType.collected;
  final ScrollController _scrollController = ScrollController();
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
  bool _activationCompleted = false;
  bool _activationScheduled = false;
  bool _accountHydrationScheduled = false;
  bool _accountHydrationCompleted = false;
  late final AppLanguageProvider _languageProvider;

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      (widget.activeTabIndexListenable == null ||
          widget.activeTabIndexListenable!.value == tabIndex) &&
      (widget.activeSectionListenable == null ||
          widget.activeSectionListenable!.value == widget.sectionIndex);

  @override
  bool get handlesScrollToTop => _isActive;

  @override
  int get tabIndex => widget.tabIndex;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  UiOperationService get _operations => ref.read(uiOperationServiceProvider);

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return _isActive ? ref.watch(provider) : ref.read(provider);
  }

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
    _languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _languageProvider.addListener(_handleAppLanguageChanged);
    widget.activeTabIndexListenable?.addListener(_handleActiveStateChanged);
    widget.activeSectionListenable?.addListener(_handleActiveStateChanged);
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isActive) return;
      _scheduleHeaderMeasurement(force: true);
      _ensureActivated();
    });
  }

  void _handleActiveStateChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_isActive) {
      _activationScheduled = false;
      _accountHydrationScheduled = false;
      return;
    }
    _scheduleHeaderMeasurement();
    _ensureActivated();
  }

  void _ensureActivated() {
    if (!_isActive) return;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final coordinator = UiInteractionCoordinator.instance;
    if (_activationCompleted) {
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
      group: 'asmr_page_activation',
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
        if (mounted && _isActive && !_activationCompleted) {
          _ensureActivated();
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
      if (!mounted || !_isActive) return;
      await _ensureCategoryLoaded(_selectedCategory);
      if (!mounted || !_isActive) return;
      setState(() => _activationCompleted = true);
      _scheduleAccountHydration(controller, generation);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_visible_activation_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _scheduleAccountHydration(
    AsmrLibraryController controller,
    int generation,
  ) {
    if (_accountHydrationCompleted ||
        _accountHydrationScheduled ||
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
      group: 'asmr_account_hydration',
      task: () async {
        _accountHydrationScheduled = false;
        if (!mounted || !_isActive || generation != coordinator.generation) {
          return;
        }
        try {
          await controller.restoreAsmrAccountSession();
          if (controller.isAsmrAccountLoggedIn) {
            await controller.syncAsmrAccount();
          }
          _accountHydrationCompleted = true;
        } catch (error, stackTrace) {
          AppLogService.warning(
            'asmr_account_hydration_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      },
    );
    if (!accepted) _accountHydrationScheduled = false;
  }

  @override
  void didUpdateWidget(covariant AsmrTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabIndexListenable != widget.activeTabIndexListenable) {
      oldWidget.activeTabIndexListenable?.removeListener(
        _handleActiveStateChanged,
      );
      widget.activeTabIndexListenable?.addListener(_handleActiveStateChanged);
    }
    if (oldWidget.activeSectionListenable != widget.activeSectionListenable) {
      oldWidget.activeSectionListenable?.removeListener(
        _handleActiveStateChanged,
      );
      widget.activeSectionListenable?.addListener(_handleActiveStateChanged);
    }
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
  }

  bool _categoryNeedsRefresh(
    AsmrLibraryController controller,
    AsmrCategoryType category,
  ) {
    return controller.worksFor(category).isEmpty ||
        controller.activeQueryFor(category).isNotEmpty;
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
      final h = measuredHeight;
      if (h > 0 &&
          (force || _headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
        setState(() => _headerHeight = h);
      }
    }
  }

  Future<void> _ensureCategoryLoaded(AsmrCategoryType category) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    if (!_categoryNeedsRefresh(controller, category)) return;
    await _runCategoryRefresh(category);
  }

  Future<void> _runCategoryRefresh(AsmrCategoryType category) {
    return _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: () =>
          ref
              .read(asmrLibraryControllerProvider)
              ?.refreshCategory(category) ??
          Future<void>.value(),
    );
  }

  void _selectCategory(AsmrCategoryType category) {
    if (_selectedCategory == category) return;
    setState(() {
      _selectedCategory = category;
    });
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller != null && controller.worksFor(category).isEmpty) {
      unawaited(
        _runAsmrOperation<void>(
          scope: UiOperationScope.asmrCategory(
            AsmrOperationKind.refresh,
            category.name,
          ),
          labelKey: 'loading_dot',
          task: () => controller.refreshCategory(category),
        ),
      );
    }
  }

  Widget _buildCategorySwitcher(AppLanguageProvider i18n) {
    return HeaderSegmentedCategoryBar<AsmrCategoryType>(
      items: _headerCategories,
      selected: _selectedCategory,
      onSelected: _selectCategory,
      labelBuilder: (category) => i18n.tr(_asmrCategoryLabelKey(category)),
    );
  }

  Future<void> _refreshCategoryWithFeedback({
    bool showSnackbar = false,
  }) async {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final beforeIds = controller
        .filteredWorksFor(_selectedCategory)
        .map((work) => work.id)
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
        .map((work) => work.id)
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
      buildAppSearchPageRoute<void>(
        context: context,
        child: const _AsmrSearchPage(),
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
    _languageProvider.removeListener(_handleAppLanguageChanged);
    widget.activeTabIndexListenable?.removeListener(_handleActiveStateChanged);
    widget.activeSectionListenable?.removeListener(_handleActiveStateChanged);
    disposeTabState();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final globalState = _readOrWatch(asmrLibraryGlobalStateProvider).value;
    final hasDownloadManager =
        _readOrWatch(asmrDownloadManagerProvider) != null;
    _readOrWatch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (_lastHeaderMeasureLanguage != i18n.language) {
      _lastHeaderMeasureLanguage = i18n.language;
      _scheduleHeaderMeasurement(force: true);
    }
    _schedulePageLanguageSync(i18n.language);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final bottomInset = MobileOverlayInset.of(context);
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : _minimumExpandedHeaderHeight(context);
    final headerContentHeight = effectiveHeaderHeight + 4.0;
    final globalInitialized = globalState?.initialized ?? false;
    final categoryState = ref.watch(
      asmrCategoryStateProvider((
        category: _selectedCategory,
        searchQuery: '',
      )),
    ).value;
    final totalWorks = (categoryState?.totalCount ?? 0) > 0
        ? categoryState!.totalCount
        : (categoryState?.works.length ?? 0);
    final asmrStatsText = i18n.tr(
      'asmr_header_stats',
      {'count': totalWorks.toString()},
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ColoredBox(color: Theme.of(context).colorScheme.surface),
        ),
        RepaintBoundary(
          child: PlaceholderContentTransition(
            showPlaceholder: !globalInitialized,
            placeholder: ListView(
              key: const ValueKey('asmr_initial_placeholder'),
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                LibraryLikeCardMetrics.listHorizontalPadding,
                headerContentHeight,
                LibraryLikeCardMetrics.listHorizontalPadding,
                bottomInset + 24,
              ),
              children: [
                for (int i = 0; i < 5; i++) const LibraryLikeSkeletonCard(),
              ],
            ),
            content: _AsmrCategoryList(
              key: ValueKey(_selectedCategory),
              isActive: _isActive,
              category: _selectedCategory,
              isLoadPending: !_activationCompleted,
              scrollController: _scrollController,
              searchQuery: '',
              topInset: headerContentHeight,
              bottomInset: bottomInset,
              onRefresh: _refreshCategoryWithFeedback,
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            collapseController: _scrollController,
            topCapsuleTitle: 'ASMR.ONE',
            topCapsuleData: asmrStatsText,
            title: 'ASMR.ONE',
            titleWidget: _buildCategorySwitcher(i18n),
            onTitleSwipeLeft: widget.onTitleSwipeLeft,
            onTitleSwipeRight: widget.onTitleSwipeRight,
            trailing: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HeaderFloatingButton(
                    child: IconButton(
                      key: const ValueKey<String>('asmr_search_button'),
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
                        onPressed: globalInitialized
                            ? () => unawaited(
                                _refreshCategoryWithFeedback(showSnackbar: true),
                              )
                            : null,
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: i18n.tr('refresh'),
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
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
                    child: _AsmrAccountButton(onPressed: _showAccountDialog),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _schedulePageLanguageSync(AppLanguage language) {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null ||
        !controller.initialized ||
        controller.pageLanguage == language ||
        _pendingPageLanguageSync == language) {
      return;
    }
    _pendingPageLanguageSync = language;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _pendingPageLanguageSync != language) return;
      _pendingPageLanguageSync = null;
      final changed = controller.setPageLanguage(language);
      if (changed && mounted) {
        await _runCategoryRefresh(_selectedCategory);
      }
    });
  }

  void _handleAppLanguageChanged() {
    if (!mounted) return;
    _schedulePageLanguageSync(_languageProvider.language);
  }
}
