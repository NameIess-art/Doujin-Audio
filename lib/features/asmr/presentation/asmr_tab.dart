import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_scroll_physics.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
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
    this.activeSectionListenable,
    this.sectionIndex = 0,
    this.onTitleSwipeRight,
  });

  final ValueListenable<int>? activeSectionListenable;
  final int sectionIndex;
  final VoidCallback? onTitleSwipeRight;

  @override
  ConsumerState<AsmrTab> createState() => _AsmrTabState();
}

class _AsmrTabState extends ConsumerState<AsmrTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<AsmrTab> {
  static const AsmrCategoryType _mainCategory = AsmrCategoryType.collected;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  double? _lastHeaderMeasureWidth;
  double? _lastHeaderMeasureTopPadding;
  double? _lastHeaderMeasureTextScale;
  AppLanguage? _pendingPageLanguageSync;

  @override
  bool get wantKeepAlive => true;

  @override
  bool get handlesScrollToTop =>
      widget.activeSectionListenable == null ||
      widget.activeSectionListenable!.value == widget.sectionIndex;

  @override
  int get tabIndex => 0;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  UiOperationService get _operations => ref.read(uiOperationServiceProvider);

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
          await _ensureCollectedLoaded();
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

  bool _collectedNeedsRefresh(AsmrLibraryController controller) {
    return controller.worksFor(_mainCategory).isEmpty ||
        controller.activeQueryFor(_mainCategory).isNotEmpty;
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final measuredHeight = box.size.height;
      final minimumHeight = _minimumExpandedHeaderHeight(context);
      final h = measuredHeight < minimumHeight ? minimumHeight : measuredHeight;
      if (h > 0 && (_headerHeight == 0 || h > _headerHeight + 0.5)) {
        setState(() => _headerHeight = h);
      }
    }
  }

  Future<void> _ensureCollectedLoaded() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    if (!_collectedNeedsRefresh(controller)) return;
    await _runCollectedRefresh();
  }

  Future<void> _runCollectedRefresh() {
    return _runAsmrOperation<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        _mainCategory.name,
      ),
      labelKey: 'loading_dot',
      task: () =>
          ref
              .read(asmrLibraryControllerProvider)
              ?.refreshCategory(_mainCategory) ??
          Future<void>.value(),
    );
  }

  Future<void> _refreshCollectedWithFeedback({
    bool showSnackbar = false,
  }) async {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final beforeIds = controller
        .filteredWorksFor(_mainCategory)
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

    await _runCollectedRefresh();

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
        .filteredWorksFor(_mainCategory)
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
    _scrollController.dispose();
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
    final collectedState = ref
        .watch(
          asmrCategoryStateProvider((category: _mainCategory, searchQuery: '')),
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
        collectedState == null ||
            (collectedState.works.isEmpty &&
                !collectedState.hasAttemptedLoad) ||
            collectedState.isLoading
        ? i18n.tr('loading_dot')
        : i18n.tr('asmr_collected_count', {'count': collectedCount});
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final bottomInset = MobileOverlayInset.of(context);
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : _minimumExpandedHeaderHeight(context);
    final headerContentHeight = effectiveHeaderHeight + 4;

    if (globalState == null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ColoredBox(color: Theme.of(context).colorScheme.surface),
          ),
          ListView(
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: _headerKey,
              title: 'ASMR.ONE',
              onTitleSwipeRight: widget.onTitleSwipeRight,
              subtitle: collectedSubtitle,
              subtitleFontSize: 11,
              fitSubtitleToWidth: true,
              trailing: IconButton(
                key: const ValueKey<String>('asmr_search_button'),
                onPressed: _openSearchPage,
                icon: const Icon(Icons.search_rounded),
                tooltip: i18n.tr('search'),
              ),
              collapseController: _scrollController,
              floatingReveal: true,
              floatingRevealDistance: 56,
              bottomSpacing: 4,
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
            key: const ValueKey(_mainCategory),
            category: _mainCategory,
            isLoadPending: false,
            scrollController: _scrollController,
            searchQuery: '',
            topInset: headerContentHeight,
            bottomInset: bottomInset,
            onRefresh: _refreshCollectedWithFeedback,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            title: 'ASMR.ONE',
            onTitleSwipeRight: widget.onTitleSwipeRight,
            subtitle: collectedSubtitle,
            subtitleFontSize: 11,
            fitSubtitleToWidth: true,
            trailing: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    key: const ValueKey<String>('asmr_search_button'),
                    onPressed: _openSearchPage,
                    icon: const Icon(Icons.search_rounded),
                    tooltip: i18n.tr('search'),
                  ),
                  if (isLandscape)
                    IconButton(
                      onPressed: globalState.initialized
                          ? () => unawaited(
                              _refreshCollectedWithFeedback(showSnackbar: true),
                            )
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: i18n.tr('refresh'),
                    ),
                  if (hasDownloadManager)
                    const _AsmrDownloadProgressInlineButton(),
                  _AsmrAccountButton(onPressed: _showAccountDialog),
                ],
              ),
            ),
            collapseController: _scrollController,
            floatingReveal: true,
            floatingRevealDistance: 56,
            bottomSpacing: 4,
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
        await _runCollectedRefresh();
      }
    });
  }
}
