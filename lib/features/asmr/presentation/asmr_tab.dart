import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/asmr_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../application/asmr_download_manager.dart';
import '../application/asmr_api_service.dart';
import '../application/asmr_library_controller.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';

import 'asmr_download_page.dart';
import 'asmr_work_detail_sheet.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';

part 'asmr_tab_header.dart';
part 'asmr_tab_category_list.dart';
part 'asmr_tab_panel.dart';
part 'asmr_tab_work_tree.dart';
part 'asmr_tab_cover.dart';

class AsmrTab extends ConsumerStatefulWidget {
  const AsmrTab({super.key});

  @override
  ConsumerState<AsmrTab> createState() => _AsmrTabState();
}

class _AsmrTabState extends ConsumerState<AsmrTab>
    with
        AutomaticKeepAliveClientMixin,
        TickerProviderStateMixin,
        MainTabStateMixin<AsmrTab> {
  final List<AsmrCategoryType> _categories = kAsmrSelectableCategories;
  late final TabController _tabController = TabController(
    length: _categories.length,
    vsync: this,
  );
  late final Map<AsmrCategoryType, ScrollController> _scrollControllers =
      <AsmrCategoryType, ScrollController>{
        for (final category in _categories) category: ScrollController(),
      };
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer;
  final Object _tabSwitchInteraction = Object();
  int _lastHandledTabIndex = 0;
  String _searchQuery = '';
  final GlobalKey _headerKey = GlobalKey();
  final ScrollController _categoryScrollController = ScrollController();
  double _headerHeight = 0;
  double? _lastHeaderMeasureWidth;
  double? _lastHeaderMeasureTopPadding;
  double? _lastHeaderMeasureTextScale;
  AppLanguage? _pendingPageLanguageSync;

  @override
  bool get wantKeepAlive => true;

  @override
  int get tabIndex => 0;

  @override
  double get headerControlsFullHeight => 86.0;

  @override
  ScrollController get mainScrollController =>
      _scrollControllers[_currentCategory] ?? _categoryScrollController;

  AsmrCategoryType get _currentCategory {
    final index = _tabController.index;
    if (index < 0 || index >= _categories.length) {
      return _categories.first;
    }
    return _categories[index];
  }

  String get _normalizedSearchQuery => normalizeSearchQuery(_searchQuery);

  UiOperationService get _operations => UiOperationService.instance;

  double _minimumExpandedHeaderHeight(BuildContext context) {
    return 72 + MediaQuery.paddingOf(context).top;
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
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
    _tabController.addListener(_handleTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final asmrController = ref.read(asmrLibraryControllerProvider);
      if (asmrController == null) {
        return;
      }
      _measureHeader();
      final defaultLanguage = AsmrContentLanguage.fromAppLanguageName(
        ref.read(appLanguageProviderInstanceProvider).language.name,
      );
      unawaited(
        asmrController.initialize(defaultLanguage: defaultLanguage).then((
          _,
        ) async {
          if (!mounted) {
            return;
          }
          await _ensureCategoryLoaded(_currentCategory);
          if (!mounted) {
            return;
          }
          await asmrController.restoreAsmrAccountSession();
          if (!mounted || !asmrController.isAsmrAccountLoggedIn) {
            return;
          }
          unawaited(asmrController.syncAsmrAccount());
        }),
      );
    });
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
      _headerHeight = 0;
    }
  }

  void _handleTabChanged() {
    if (!mounted) return;
    final coordinator = UiInteractionCoordinator.instance;
    if (_tabController.indexIsChanging) {
      coordinator.beginInteraction(_tabSwitchInteraction);
      setState(() {});
      return;
    }
    if (_lastHandledTabIndex == _tabController.index) return;
    _lastHandledTabIndex = _tabController.index;
    setState(() {});
    final category = _currentCategory;
    final generation = coordinator.beginGeneration();
    coordinator.endInteraction(_tabSwitchInteraction);
    coordinator.scheduleAfterIdle(
      key: 'asmr_category_${category.name}_$_normalizedSearchQuery',
      generation: generation,
      priority: 0,
      task: () => _ensureCategoryLoaded(category),
    );
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final globalState = ref
          .read(asmrLibraryControllerProvider)
          ?.globalViewState;
      final hasControls = globalState != null;
      final measuredHeight =
          box.size.height - (hasControls ? headerControlsFullHeight : 0);
      final minimumHeight = _minimumExpandedHeaderHeight(context);
      final h = measuredHeight < minimumHeight ? minimumHeight : measuredHeight;
      if (h > 0 && (_headerHeight == 0 || h > _headerHeight + 0.5)) {
        setState(() => _headerHeight = h);
      }
    }
  }

  Future<void> _ensureCategoryLoaded(AsmrCategoryType category) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final needsRefresh =
        controller.worksFor(category).isEmpty ||
        controller.activeQueryFor(category) != _normalizedSearchQuery;
    if (!needsRefresh) {
      return;
    }
    await _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: () =>
          controller.refreshCategory(category, searchQuery: _searchQuery),
    );
  }

  Future<void> _refreshCurrentCategory() {
    final category = _currentCategory;
    return _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: () async {
        final controller = ref.read(asmrLibraryControllerProvider);
        if (controller == null) return;
        await controller.refreshCategory(category, searchQuery: _searchQuery);
      },
    );
  }

  Future<void> _refreshCategoryWithFeedback(
    AsmrCategoryType category, {
    bool showSnackbar = false,
  }) async {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final beforeIds = controller
        .filteredWorksFor(category, searchQuery: _searchQuery)
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

    await _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: () =>
          controller.refreshCategory(category, searchQuery: _searchQuery),
    );

    if (!mounted) {
      return;
    }

    if (controller.lastError != null) {
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
        .filteredWorksFor(category, searchQuery: _searchQuery)
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

  void _onSearchChanged(String value) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) {
        return;
      }
      final nextQuery = value.trim();
      if (_searchQuery == nextQuery) {
        return;
      }
      setState(() {
        _searchQuery = nextQuery;
      });
      final controller = _scrollControllers[_currentCategory];
      if (controller != null && controller.hasClients) {
        controller.jumpTo(0);
      }
      unawaited(_refreshCurrentCategory());
    });
  }

  Future<T?> _showAsmrPanel<T>({required WidgetBuilder builder}) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return showGeneralDialog<T>(
      context: context,
      barrierLabel: i18n.tr('close'),
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: kSecondaryOverlayConfig.transitionDuration,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _AsmrPanelOverlay(animation: animation, builder: builder);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
    );
  }

  Future<void> _showAccountDialog() {
    return _showAsmrPanel<void>(
      builder: (context) => const _AsmrAccountPanel(),
    );
  }

  @override
  void dispose() {
    disposeTabState();
    UiInteractionCoordinator.instance.cancelInteraction(_tabSwitchInteraction);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _categoryScrollController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureHeader();
    });
    final globalState = ref.watch(asmrLibraryGlobalStateProvider).value;
    final hasDownloadManager = ref.watch(asmrDownloadManagerProvider) != null;
    final currentCategory = _currentCategory;
    final currentCategoryState = ref
        .watch(
          asmrCategoryStateProvider((
            category: currentCategory,
            searchQuery: _normalizedSearchQuery,
          )),
        )
        .value;
    final collectedCount =
        ref
            .read(asmrLibraryControllerProvider)
            ?.totalCountFor(AsmrCategoryType.collected) ??
        0;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    _schedulePageLanguageSync(i18n.language);
    final collectedSubtitle =
        currentCategoryState == null ||
            (currentCategoryState.works.isEmpty &&
                !currentCategoryState.hasAttemptedLoad &&
                currentCategoryState.lastError == null) ||
            currentCategoryState.isLoading
        ? i18n.tr('loading_dot')
        : i18n.tr('asmr_collected_count', {'count': collectedCount});
    final currentScrollController = _scrollControllers[currentCategory]!;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final bottomInset = MobileOverlayInset.of(context);
    final headerControlsFullHeight = this.headerControlsFullHeight;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : _minimumExpandedHeaderHeight(context);
    final topTotalHeight = effectiveHeaderHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;

    Widget collapsingHeaderControls() {
      return _AsmrCollapsingHeaderControls(
        controller: currentScrollController,
        height: headerControlsFullHeight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 42,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 1, 12, 7),
                child: AnimatedBuilder(
                  animation: _tabController,
                  builder: (context, _) {
                    final screenWidth = MediaQuery.sizeOf(context).width;
                    const totalHorizontalPadding = 24.0;

                    final isPortraitMobile =
                        MediaQuery.orientationOf(context) ==
                        Orientation.portrait;

                    final itemWidth = isPortraitMobile
                        ? (screenWidth - totalHorizontalPadding - 24.0) / 4
                        : 86.0;

                    return Listener(
                      onPointerSignal: (pointerSignal) {
                        if (pointerSignal is PointerScrollEvent) {
                          if (_categoryScrollController.hasClients) {
                            final newOffset =
                                _categoryScrollController.offset +
                                pointerSignal.scrollDelta.dy;
                            _categoryScrollController.jumpTo(
                              newOffset.clamp(
                                0.0,
                                _categoryScrollController
                                    .position
                                    .maxScrollExtent,
                              ),
                            );
                          }
                        }
                      },
                      child: ListView.separated(
                        controller: _categoryScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: _categories.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          return SizedBox(
                            width: itemWidth,
                            child: _AsmrCategoryButton(
                              label: i18n.tr(
                                _asmrCategoryLabelKey(_categories[index]),
                              ),
                              selected: _tabController.index == index,
                              onTap: () {
                                if (_tabController.index == index) {
                                  return;
                                }
                                FocusScope.of(context).unfocus();
                                _tabController.animateTo(index);
                              },
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
            _AsmrSearchBar(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onClear: () {
                _searchController.clear();
                _searchDebounceTimer?.cancel();
                if (_searchQuery.isEmpty) {
                  return;
                }
                setState(() {
                  _searchQuery = '';
                });
                unawaited(_refreshCurrentCategory());
              },
            ),
          ],
        ),
      );
    }

    if (globalState == null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ColoredBox(color: Theme.of(context).colorScheme.surface),
          ),
          ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, headerContentHeight, 16, 0),
            children: [
              for (int i = 0; i < 5; i++)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: LibraryLikeSkeletonCard(),
                ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: _headerKey,
              title: 'ASMR.ONE',
              subtitle: collectedSubtitle,
              subtitleFontSize: 11,
              fitSubtitleToWidth: true,
              collapseController: currentScrollController,
              collapseDistance: headerControlsFullHeight,
              floatingReveal: true,
              floatingRevealDistance: 56,
              bottomSpacing: 4,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              additionalChild: collapsingHeaderControls(),
            ),
          ),
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ColoredBox(color: Theme.of(context).colorScheme.surface),
        ),
        PlaceholderContentTransition(
          showPlaceholder: !globalState.initialized,
          placeholder: ListView(
            key: const ValueKey('asmr_initial_placeholder'),
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, headerContentHeight, 16, 0),
            children: [
              for (int i = 0; i < 5; i++)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: LibraryLikeSkeletonCard(),
                ),
            ],
          ),
          content: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              for (int i = 0; i < _categories.length; i++)
                (() {
                  final category = _categories[i];
                  final isActive = category == currentCategory;
                  return IgnorePointer(
                    ignoring: !isActive,
                    child: AnimatedOpacity(
                      key: ValueKey<String>('asmr_category_fade_$i'),
                      opacity: isActive ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOutCubic,
                      child: TickerMode(
                        enabled: isActive,
                        child: ExcludeFocus(
                          excluding: !isActive,
                          child: ExcludeSemantics(
                            excluding: !isActive,
                            child: _AsmrCategoryList(
                              key: ValueKey(category),
                              category: category,
                              scrollController: _scrollControllers[category]!,
                              searchQuery: _searchQuery,
                              topInset: headerContentHeight,
                              bottomInset: bottomInset,
                              onRefresh: () =>
                                  _refreshCategoryWithFeedback(category),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                })(),
            ],
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            title: 'ASMR.ONE',
            subtitle: collectedSubtitle,
            subtitleFontSize: 11,
            fitSubtitleToWidth: true,
            trailing: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isLandscape)
                    IconButton(
                      onPressed: globalState.initialized
                          ? () => unawaited(
                              _refreshCategoryWithFeedback(
                                currentCategory,
                                showSnackbar: true,
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Refresh',
                    ),
                  if (hasDownloadManager)
                    const _AsmrDownloadProgressInlineButton(),
                  _AsmrAccountButton(onPressed: _showAccountDialog),
                ],
              ),
            ),
            collapseController: currentScrollController,
            collapseDistance: headerControlsFullHeight,
            floatingReveal: true,
            floatingRevealDistance: 56,
            bottomSpacing: 4,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            additionalChild: collapsingHeaderControls(),
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
        await _refreshCurrentCategory();
      }
    });
  }
}
