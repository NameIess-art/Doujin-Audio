import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import '../services/asmr_download_manager.dart';
import '../services/asmr_library_controller.dart';
import '../services/search_query_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/glass_refresh_indicator.dart';
import '../widgets/marquee_text.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/scroll_activity_gate.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';
import 'asmr_download_page.dart';
import 'asmr_work_detail_sheet.dart';

class AsmrTab extends StatefulWidget {
  const AsmrTab({super.key});

  @override
  State<AsmrTab> createState() => _AsmrTabState();
}

const Color _kAsmrBlueLight = Color(0xFF1D4ED8);
const Color _kAsmrBlueDark = Color(0xFF3B82F6);

class _AsmrTabState extends State<AsmrTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  List<AsmrCategoryType> _categories = kDefaultVisibleAsmrCategories;
  late TabController _tabController = TabController(
    length: _categories.length,
    vsync: this,
  );
  late final Map<AsmrCategoryType, ScrollController> _scrollControllers =
      <AsmrCategoryType, ScrollController>{
        for (final category in _categories)
          category: ScrollController()
            ..addListener(() => _handleCategoryScroll(category)),
      };
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer;
  final Map<AsmrCategoryType, Timer> _loadMoreDebounceTimers =
      <AsmrCategoryType, Timer>{};
  ValueListenable<int?>? _scrollToTopTabListenable;
  String _searchQuery = '';
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 72;

  @override
  bool get wantKeepAlive => true;

  AsmrCategoryType get _currentCategory {
    final index = _tabController.index;
    if (index < 0 || index >= _categories.length) {
      return _categories.first;
    }
    return _categories[index];
  }

  String get _normalizedSearchQuery => normalizeSearchQuery(_searchQuery);

  double get _headerControlsFullHeight => 86.0;

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_handleTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final asmrController = context.read<AsmrLibraryController?>();
      if (asmrController == null) {
        return;
      }
      _scrollToTopTabListenable = context
          .read<AudioProvider>()
          .scrollToTopTabListenable;
      _scrollToTopTabListenable?.addListener(_handleScrollToTopSignal);
      _measureHeader();
      final defaultLanguage = AsmrContentLanguage.fromAppLanguageName(
        context.read<AppLanguageProvider>().language.name,
      );
      unawaited(
        asmrController.initialize(defaultLanguage: defaultLanguage).then((_) {
          if (!mounted) {
            return;
          }
          _syncCategoryTabs(asmrController.visibleCategories);
          unawaited(_ensureCategoryLoaded(_currentCategory));
        }),
      );
    });
  }

  void _syncCategoryTabs(List<AsmrCategoryType> categories) {
    final nextCategories = categories.isEmpty
        ? kDefaultVisibleAsmrCategories
        : categories.toList(growable: false);
    if (listEquals(_categories, nextCategories)) {
      return;
    }
    final previousCategory = _currentCategory;
    for (final category in nextCategories) {
      _scrollControllers.putIfAbsent(
        category,
        () =>
            ScrollController()
              ..addListener(() => _handleCategoryScroll(category)),
      );
    }
    final removed = _scrollControllers.keys
        .where((category) => !nextCategories.contains(category))
        .toList(growable: false);
    for (final category in removed) {
      _loadMoreDebounceTimers.remove(category)?.cancel();
      _scrollControllers.remove(category)?.dispose();
    }
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    final nextIndex = nextCategories.indexOf(previousCategory);
    _categories = nextCategories;
    _tabController = TabController(
      length: _categories.length,
      initialIndex: nextIndex < 0 ? 0 : nextIndex,
      vsync: this,
    )..addListener(_handleTabChanged);
    if (mounted) {
      setState(() {});
    }
  }

  void _handleCategoryScroll(AsmrCategoryType category) {
    final controller = _scrollControllers[category];
    if (controller == null || !controller.hasClients) {
      return;
    }
    if (controller.position.extentAfter > 280) {
      return;
    }
    if (_loadMoreDebounceTimers.containsKey(category)) {
      return;
    }
    _loadMoreDebounceTimers[category] = Timer(
      const Duration(milliseconds: 180),
      () {
        _loadMoreDebounceTimers.remove(category);
        if (!mounted) {
          return;
        }
        unawaited(
          context.read<AsmrLibraryController>().loadMoreCategory(
            category,
            searchQuery: _searchQuery,
          ),
        );
      },
    );
  }

  void _handleTabChanged() {
    if (!mounted || _tabController.indexIsChanging) {
      return;
    }
    setState(() {});
    unawaited(_ensureCategoryLoaded(_currentCategory));
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

  void _handleScrollToTopSignal() {
    if (!mounted || _scrollToTopTabListenable?.value != 0) {
      return;
    }
    final controller = _scrollControllers[_currentCategory];
    if (controller == null || !controller.hasClients) {
      return;
    }
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _ensureCategoryLoaded(AsmrCategoryType category) async {
    final controller = context.read<AsmrLibraryController>();
    final needsRefresh =
        controller.worksFor(category).isEmpty ||
        controller.activeQueryFor(category) != _normalizedSearchQuery;
    if (!needsRefresh) {
      return;
    }
    await controller.refreshCategory(category, searchQuery: _searchQuery);
  }

  Future<void> _refreshCurrentCategory() {
    return context.read<AsmrLibraryController>().refreshCategory(
      _currentCategory,
      searchQuery: _searchQuery,
    );
  }

  Future<void> _refreshCategoryWithFeedback(AsmrCategoryType category) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final beforeIds = controller
        .filteredWorksFor(category, searchQuery: _searchQuery)
        .map((work) => work.id)
        .toList(growable: false);

    await Future.wait(<Future<void>>[
      controller.refreshCategory(category, searchQuery: _searchQuery),
      if (controller.isAsmrAccountLoggedIn)
        controller.syncAsmrAccount(force: true),
    ]);
    
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
    final i18n = context.read<AppLanguageProvider>();
    return showGeneralDialog<T>(
      context: context,
      barrierLabel: i18n.tr('close'),
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _AsmrPanelOverlay(animation: animation, builder: builder);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
    );
  }

  Future<void> _showCategoryDialog() async {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final selected = controller.visibleCategories.toSet();
    final result = await _showAsmrPanel<List<AsmrCategoryType>>(
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return _AsmrPanelCard(
              icon: Icons.category_rounded,
              title: i18n.tr('asmr_categories_title'),
              actions: [
                _AsmrPanelAction(
                  label: i18n.tr('close'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                _AsmrPanelAction(
                  label: i18n.tr('done'),
                  filled: true,
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          final ordered = kAsmrSelectableCategories
                              .where(selected.contains)
                              .toList(growable: false);
                          Navigator.of(context).pop(ordered);
                        },
                ),
              ],
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final category in kAsmrSelectableCategories)
                      CheckboxListTile(
                        value: selected.contains(category),
                        onChanged:
                            !Platform.isWindows &&
                                !selected.contains(category) &&
                                selected.length >= 5
                            ? null
                            : (checked) {
                                setDialogState(() {
                                  if (checked == true) {
                                    selected.add(category);
                                  } else if (selected.length > 1) {
                                    selected.remove(category);
                                  }
                                });
                              },
                        title: Text(i18n.tr(_asmrCategoryLabelKey(category))),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted || result == null) {
      return;
    }
    await controller.setVisibleCategories(result);
    if (!mounted) {
      return;
    }
    _syncCategoryTabs(controller.visibleCategories);
    unawaited(_ensureCategoryLoaded(_currentCategory));
  }

  Future<void> _showLanguageDialog() async {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final result = await _showAsmrPanel<AsmrContentLanguage>(
      builder: (context) => _AsmrPanelCard(
        icon: Icons.language_rounded,
        title: i18n.tr('asmr_language_title'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final language in AsmrContentLanguage.values)
              _AsmrSelectionTile(
                label: i18n.tr(_asmrLanguageLabelKey(language)),
                selected: controller.contentLanguage == language,
                onTap: () => Navigator.of(context).pop(language),
              ),
          ],
        ),
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    await controller.setContentLanguage(result);
    if (!mounted) {
      return;
    }
    unawaited(_refreshCurrentCategory());
  }

  Future<void> _showAccountDialog() {
    return _showAsmrPanel<void>(
      builder: (context) => const _AsmrAccountPanel(),
    );
  }

  @override
  void dispose() {
    _scrollToTopTabListenable?.removeListener(_handleScrollToTopSignal);
    _searchDebounceTimer?.cancel();
    for (final timer in _loadMoreDebounceTimers.values) {
      timer.cancel();
    }
    _loadMoreDebounceTimers.clear();
    _searchController.dispose();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final globalState = context
        .select<AsmrLibraryController?, AsmrLibraryGlobalViewState?>(
          (controller) => controller?.globalViewState,
        );
    final hasDownloadManager = context.select<AsmrDownloadManager?, bool>(
      (manager) => manager != null,
    );
    final collectedCount = context.select<AsmrLibraryController?, int>(
      (controller) =>
          controller?.totalCountFor(AsmrCategoryType.collected) ?? 0,
    );
    final i18n = context.watch<AppLanguageProvider>();
    final currentCategory = _currentCategory;
    final currentScrollController = _scrollControllers[currentCategory]!;
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final bottomInset = MobileOverlayInset.of(context);
    final headerControlsFullHeight = _headerControlsFullHeight;
    final topTotalHeight = _headerHeight + 4;
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
                child: Row(
                  children: [
                    for (var index = 0; index < _categories.length; index++) ...[
                      if (index > 0) const SizedBox(width: 8),
                      Expanded(
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
                      ),
                    ],
                  ],
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
          ShimmerLoader(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(16, headerContentHeight + 10, 16, 0),
              children: [
                for (int i = 0; i < 5; i++)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: _AsmrWorkSkeletonCard(),
                  ),
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
              isLoading: true,
              bottomSpacing: 4,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            ),
          ),
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        globalState.initialized
            ? TabBarView(
                controller: _tabController,
                children: [
                  for (final category in _categories)
                    TickerMode(
                      enabled: category == currentCategory,
                      child: _AsmrCategoryList(
                        key: ValueKey(category),
                        category: category,
                        scrollController: _scrollControllers[category]!,
                        searchQuery: _searchQuery,
                        topInset: headerContentHeight,
                        bottomInset: bottomInset,
                        onRefresh: () => _refreshCategoryWithFeedback(category),
                      ),
                    ),
                ],
              )
            : ShimmerLoader(
                child: ListView(
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    headerContentHeight + 10,
                    16,
                    0,
                  ),
                  children: [
                    for (int i = 0; i < 5; i++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: _AsmrWorkSkeletonCard(),
                      ),
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
            subtitle: i18n.tr('asmr_collected_count', {
              'count': collectedCount,
            }),
            subtitleFontSize: 11,
            fitSubtitleToWidth: true,
            trailing: SizedBox(
              width: isWindows ? 104 : 52,
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isWindows)
                    IconButton(
                      onPressed: globalState.initialized
                          ? () => unawaited(
                              _refreshCategoryWithFeedback(currentCategory),
                            )
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Refresh',
                    ),
                  _AsmrMoreMenuButton(
                    onAccount: _showAccountDialog,
                    onCategories: _showCategoryDialog,
                    onLanguage: _showLanguageDialog,
                  ),
                ],
              ),
            ),
            isLoading: !globalState.initialized,
            bottomSpacing: 4,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            backgroundOpacity: isWindows ? 1 : null,
            additionalChild: collapsingHeaderControls(),
          ),
        ),
        if (hasDownloadManager)
          _AsmrDownloadProgressButton(bottomInset: bottomInset),
      ],
    );
  }
}

class _AsmrDownloadProgressButton extends StatelessWidget {
  const _AsmrDownloadProgressButton({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<AsmrDownloadManager, AsmrDownloadButtonViewState>(
          (manager) => manager.buttonViewState,
        );
    return Positioned(
      right: 16,
      bottom: bottomInset + 18,
      child: IgnorePointer(
        ignoring: !state.visible,
        child: AnimatedOpacity(
          opacity: state.visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: state.visible ? 1 : 0.92,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: FloatingActionButton.small(
              heroTag: 'asmr-one-download-progress',
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: Theme.of(
                context,
              ).colorScheme.onSecondaryContainer,
              elevation: 0,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AsmrDownloadTaskPage(),
                  ),
                );
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(Icons.downloading_rounded),
                  if (state.progress != null)
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        value: state.progress,
                        strokeWidth: 2.4,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer
                            .withValues(alpha: 0.78),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrCollapsingHeaderControls extends StatelessWidget {
  const _AsmrCollapsingHeaderControls({
    required this.controller,
    required this.height,
    required this.child,
  });

  final ScrollController controller;
  final double height;
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
        final hidden = offset.clamp(0.0, height);
        return SizedBox(
          height: height - hidden,
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, -hidden),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _AsmrSearchBar extends StatelessWidget {
  const _AsmrSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? _kAsmrBlueDark : _kAsmrBlueLight;
    final i18n = context.watch<AppLanguageProvider>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SizedBox(
        height: 34,
        child: TextSelectionTheme(
          data: TextSelectionThemeData(
            cursorColor: asmrBlue,
            selectionColor: asmrBlue.withValues(alpha: 0.28),
            selectionHandleColor: asmrBlue,
          ),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final hasText = value.text.isNotEmpty;
              return TextField(
                controller: controller,
                cursorColor: asmrBlue,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 13),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: cs.onSurfaceVariant,
                    size: 18,
                  ),
                  suffixIcon: hasText
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: onClear,
                          color: cs.onSurfaceVariant,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        )
                      : null,
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                  label: MarqueeText(
                    text: i18n.tr('asmr_search_hint'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    edgePadding: 0,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  isDense: true,
                ),
                onChanged: onChanged,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AsmrCategoryList extends StatefulWidget {
  const _AsmrCategoryList({
    super.key,
    required this.category,
    required this.scrollController,
    required this.searchQuery,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
  });

  final AsmrCategoryType category;
  final ScrollController scrollController;
  final String searchQuery;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;

  @override
  State<_AsmrCategoryList> createState() => _AsmrCategoryListState();
}

class _AsmrCategoryListState extends State<_AsmrCategoryList>
    with AutomaticKeepAliveClientMixin {
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();
  bool _refreshTriggeredInCurrentScroll = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.select<AsmrLibraryController, AsmrCategoryViewState>(
      (controller) => controller.categoryViewState(
        widget.category,
        searchQuery: widget.searchQuery,
      ),
    );
    final works = state.works;
    final i18n = context.watch<AppLanguageProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return Theme(
      data: theme.copyWith(
        scrollbarTheme: theme.scrollbarTheme.copyWith(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.dragged)) {
              return asmrBlue;
            }
            if (states.contains(WidgetState.hovered)) {
              return asmrBlue.withValues(alpha: 0.7);
            }
            return theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
          }),
        ),
      ),
      child: ScrollActivityGate(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(
              top: widget.topInset,
              bottom: widget.bottomInset,
              right: 4,
            ),
          ),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.dragDetails != null &&
                  notification.metrics.pixels < -68 &&
                  !_refreshTriggeredInCurrentScroll) {
                _refreshTriggeredInCurrentScroll = true;
                unawaited(HapticFeedback.mediumImpact());
                _refreshIndicatorKey.currentState?.show();
              } else if (notification is ScrollEndNotification) {
                _refreshTriggeredInCurrentScroll = false;
              }
              return false;
            },
            child: GlassRefreshIndicator(
              key: _refreshIndicatorKey,
              color: asmrBlue,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              edgeOffset: widget.topInset,
              displacement: 32,
              triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
              onRefresh: () async {
                unawaited(HapticFeedback.mediumImpact());
                await widget.onRefresh();
                await Future<void>.delayed(const Duration(milliseconds: 300));
              },
              child: ListView.builder(
                controller: widget.scrollController,
                cacheExtent: 520,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: EdgeInsets.fromLTRB(
                  16,
                  widget.topInset,
                  16,
                  widget.bottomInset + 24,
                ),
                itemCount: works.isEmpty
                    ? 1
                    : works.length +
                          ((state.isLoadingMore || state.hasMore) ? 1 : 0),
                itemBuilder: (context, index) {
                  if (works.isEmpty) {
                    if (state.isLoading) {
                      return ShimmerLoader(
                        child: Column(
                          children: [
                            for (int i = 0; i < 5; i++)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 6),
                                child: _AsmrWorkSkeletonCard(),
                              ),
                          ],
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: Center(
                        child: Text(
                          state.lastError == null
                              ? i18n.tr('asmr_empty_category')
                              : i18n.tr('asmr_refresh_failed'),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  }
                  if (index >= works.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Center(
                        child: state.isLoadingMore
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: asmrBlue,
                                ),
                              )
                            : Text(
                                i18n.tr('asmr_load_more_hint'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: RepaintBoundary(
                      child: _AsmrWorkTreeCard(
                        work: works[index],
                        searchQuery: widget.searchQuery,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrCategoryButton extends StatelessWidget {
  const _AsmrCategoryButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF3B82F6) : const Color(0xFF1D4ED8);
    final asmrBlueContainer = isDark
        ? const Color(0xFF172554)
        : const Color(0xFFDBEAFE);
    final onAsmrBlueContainer = isDark
        ? const Color(0xFFDBEAFE)
        : const Color(0xFF1E40AF);

    return Material(
      color: selected ? asmrBlueContainer : cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? asmrBlue.withValues(alpha: isDark ? 0.58 : 0.45)
              : cs.outlineVariant.withValues(alpha: isDark ? 0.68 : 1),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 34,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? onAsmrBlueContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrPanelOverlay extends StatelessWidget {
  const _AsmrPanelOverlay({required this.animation, required this.builder});

  final Animation<double> animation;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mediaSize = MediaQuery.sizeOf(context);
    final isDesktop = mediaSize.width >= 760;
    final maxWidth = isDesktop ? 472.0 : 404.0;
    final outerPadding = EdgeInsets.fromLTRB(
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 176,
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 132,
    );
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          final progress = curved.value.clamp(0.0, 1.0);
          final showBackdrop = animation.status != AnimationStatus.reverse;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: showBackdrop
                      ? ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: cs.scrim.withValues(
                                  alpha: 0.12 + (0.10 * progress),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
              ),
              SafeArea(
                child: FadeTransition(
                  opacity: curved,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
                    child: Padding(
                      padding: outerPadding,
                      child: Align(
                        alignment: isDesktop
                            ? Alignment.center
                            : Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          child: Theme(
                            data: _asmrPanelTheme(context),
                            child: Builder(builder: builder),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

ThemeData _asmrPanelTheme(BuildContext context) {
  final base = Theme.of(context);
  final isDark = base.brightness == Brightness.dark;
  final blue = isDark ? _kAsmrBlueDark : _kAsmrBlueLight;
  final blueContainer = isDark
      ? const Color(0xFF1E3A8A)
      : const Color(0xFFDBEAFE);
  final onBlueContainer = isDark
      ? const Color(0xFFBFDBFE)
      : const Color(0xFF1E40AF);
  final scheme = base.colorScheme.copyWith(
    primary: blue,
    onPrimary: Colors.white,
    primaryContainer: blueContainer,
    onPrimaryContainer: onBlueContainer,
    secondary: blue,
    onSecondary: Colors.white,
    secondaryContainer: blueContainer,
    onSecondaryContainer: onBlueContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return blue;
        }
        return null;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: blue,
        foregroundColor: Colors.white,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: blue),
    ),
    iconTheme: base.iconTheme.copyWith(color: blue),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: blue, width: 1.5),
      ),
    ),
  );
}

class _AsmrPanelCard extends StatelessWidget {
  const _AsmrPanelCard({
    required this.icon,
    required this.title,
    required this.child,
    this.actions = const <_AsmrPanelAction>[],
  });

  final IconData icon;
  final String title;
  final Widget child;
  final List<_AsmrPanelAction> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = (MediaQuery.sizeOf(context).height - 96).clamp(
      280.0,
      560.0,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          color: cs.surfaceContainerLow.withValues(alpha: 0.96),
          border: Border.all(color: cs.primary.withValues(alpha: 0.45)),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AsmrPanelTitle(icon: icon, title: title),
              const SizedBox(height: 18),
              Flexible(child: child),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrPanelTitle extends StatelessWidget {
  const _AsmrPanelTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: cs.onPrimaryContainer, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _AsmrPanelAction extends StatelessWidget {
  const _AsmrPanelAction({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      style: const TextStyle(fontWeight: FontWeight.w600),
    );
    if (filled) {
      return FilledButton(onPressed: onPressed, child: child);
    }
    return TextButton(onPressed: onPressed, child: child);
  }
}

class _AsmrSelectionTile extends StatelessWidget {
  const _AsmrSelectionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.72)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 20,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? cs.onPrimaryContainer : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrAccountPanel extends StatefulWidget {
  const _AsmrAccountPanel();

  @override
  State<_AsmrAccountPanel> createState() => _AsmrAccountPanelState();
}

class _AsmrAccountPanelState extends State<_AsmrAccountPanel> {
  final TextEditingController _accountController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_submitting) {
      return;
    }
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<AsmrLibraryController>().loginAsmrAccount(
        account,
        password,
      );
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('asmr_login_success'),
        tone: AppFeedbackTone.success,
        icon: Icons.verified_user_rounded,
        iconColor: _accountAccentColor(context),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('asmr_login_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        iconColor: _accountAccentColor(context),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _sync() async {
    if (_submitting) {
      return;
    }
    setState(() => _submitting = true);
    final controller = context.read<AsmrLibraryController>();
    try {
      await controller.syncAsmrAccount(force: true);
      if (!mounted) {
        return;
      }
      final syncState = controller.syncViewState;
      final failed = syncState.phase == AsmrSyncPhase.failed;
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr(
          failed ? 'asmr_account_sync_failed' : 'asmr_account_sync_done',
        ),
        tone: failed ? AppFeedbackTone.destructive : AppFeedbackTone.success,
        icon: failed ? Icons.sync_problem_rounded : Icons.sync_rounded,
        iconColor: _accountAccentColor(context),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _logout() async {
    if (_submitting) {
      return;
    }
    setState(() => _submitting = true);
    await context.read<AsmrLibraryController>().logoutAsmrAccount();
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    showAppSnackBar(
      context,
      context.read<AppLanguageProvider>().tr('asmr_logout_success'),
      icon: Icons.logout_rounded,
      iconColor: _accountAccentColor(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final authState = context.select<AsmrLibraryController, AsmrAuthViewState>(
      (controller) => controller.authViewState,
    );
    final syncState = context.select<AsmrLibraryController, AsmrSyncViewState>(
      (controller) => controller.syncViewState,
    );
    final syncing = syncState.phase == AsmrSyncPhase.syncing || _submitting;

    if (!authState.isLoggedIn) {
      final canLogin =
          _accountController.text.trim().isNotEmpty &&
          _passwordController.text.isNotEmpty &&
          !syncing;
      return _AsmrPanelCard(
        icon: Icons.account_circle_rounded,
        title: i18n.tr('asmr_account_title'),
        actions: [
          _AsmrPanelAction(
            label: i18n.tr('close'),
            onPressed: syncing ? null : () => Navigator.of(context).pop(),
          ),
          _AsmrPanelAction(
            label: syncing
                ? i18n.tr('asmr_account_syncing')
                : i18n.tr('asmr_login_action'),
            onPressed: canLogin ? _login : null,
            filled: true,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _accountController,
              enabled: !syncing,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: i18n.tr('asmr_login_account'),
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !syncing,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (canLogin) {
                  unawaited(_login());
                }
              },
              decoration: InputDecoration(
                labelText: i18n.tr('asmr_login_password'),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      );
    }

    final lastSyncAt = syncState.lastSyncAt;
    return _AsmrPanelCard(
      icon: Icons.account_circle_rounded,
      title: i18n.tr('asmr_account_title'),
      actions: [
        _AsmrPanelAction(
          label: i18n.tr('asmr_logout_action'),
          onPressed: syncing ? null : _logout,
        ),
        _AsmrPanelAction(
          label: syncing
              ? i18n.tr('asmr_account_syncing')
              : i18n.tr('asmr_account_sync_now'),
          onPressed: syncing ? null : _sync,
          filled: true,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AsmrAccountStatusLine(
            icon: Icons.person_outline_rounded,
            text: i18n.tr('asmr_logged_in_as', {
              'name': authState.userName.isEmpty ? '-' : authState.userName,
            }),
          ),
          const SizedBox(height: 12),
          _AsmrAccountStatusLine(
            icon: Icons.schedule_rounded,
            text: lastSyncAt == null
                ? i18n.tr('asmr_account_not_synced')
                : i18n.tr('asmr_account_last_sync', {
                    'time': _formatAsmrSyncTime(lastSyncAt),
                  }),
          ),
          const SizedBox(height: 12),
          _AsmrAccountStatusLine(
            icon: syncState.phase == AsmrSyncPhase.failed
                ? Icons.sync_problem_rounded
                : Icons.sync_rounded,
            text: _syncStatusText(i18n, syncState),
          ),
        ],
      ),
    );
  }

  String _syncStatusText(
    AppLanguageProvider i18n,
    AsmrSyncViewState syncState,
  ) {
    if (syncState.phase == AsmrSyncPhase.syncing) {
      return i18n.tr('asmr_account_syncing');
    }
    if (syncState.phase == AsmrSyncPhase.failed) {
      return i18n.tr('asmr_account_sync_failed');
    }
    if (syncState.pendingCount > 0) {
      return i18n.tr('asmr_account_pending_count', {
        'count': syncState.pendingCount.toString(),
      });
    }
    return i18n.tr('asmr_account_sync_done');
  }

  Color _accountAccentColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? _kAsmrBlueDark
        : _kAsmrBlueLight;
  }
}

class _AsmrAccountStatusLine extends StatelessWidget {
  const _AsmrAccountStatusLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAsmrSyncTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

class _AsmrMoreMenuButton extends StatelessWidget {
  const _AsmrMoreMenuButton({
    required this.onAccount,
    required this.onCategories,
    required this.onLanguage,
  });

  final VoidCallback onAccount;
  final VoidCallback onCategories;
  final VoidCallback onLanguage;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return UnifiedPopupMenuButton<_AsmrMoreAction>(
      icon: Icons.more_horiz_rounded,
      tooltip: i18n.tr('asmr_more'),
      menuWidth: 220,
      selectAfterDismiss: false,
      entries: [
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.account,
          icon: Icons.account_circle_rounded,
          label: i18n.tr('asmr_account_menu'),
        ),
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.categories,
          icon: Icons.category_rounded,
          label: i18n.tr('asmr_categories_title'),
        ),
        UnifiedMenuEntry<_AsmrMoreAction>.action(
          value: _AsmrMoreAction.language,
          icon: Icons.language_rounded,
          label: i18n.tr('asmr_language_title'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case _AsmrMoreAction.account:
            onAccount();
            break;
          case _AsmrMoreAction.categories:
            onCategories();
            break;
          case _AsmrMoreAction.language:
            onLanguage();
            break;
        }
      },
    );
  }
}

enum _AsmrMoreAction { account, categories, language }

class _AsmrWorkTreeCard extends StatefulWidget {
  const _AsmrWorkTreeCard({required this.work, required this.searchQuery});

  final AsmrWork work;
  final String searchQuery;

  @override
  State<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends State<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = 160;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  Future<void> _playWork(BuildContext context) async {
    final asmrController = context.read<AsmrLibraryController>();
    await asmrController.playWork(context.read<AudioProvider>(), widget.work);
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': widget.work.title}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final shouldFavorite = !widget.work.isFavorite;
    unawaited(controller.toggleFavorite(widget.work));
    showAppSnackBar(
      context,
      i18n.tr(shouldFavorite ? 'asmr_favorite_added' : 'asmr_favorite_removed'),
      tone: shouldFavorite ? AppFeedbackTone.success : AppFeedbackTone.warning,
      icon: shouldFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _openDownloadPage(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AsmrDownloadPage(work: widget.work),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final treeState = context
        .select<AsmrLibraryController, AsmrTrackTreeViewState>(
          (controller) => controller.trackTreeViewState(widget.work.id),
        );
    final tree = treeState.tree;
    final visibleTree = treeState.visibleTree;
    final isTreeLoading = treeState.isLoading;
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return SwipeRevealCard(
      shape: cardShape,
      actionLabel: i18n.tr('asmr_detail_action'),
      removeTooltip: i18n.tr('asmr_detail_tooltip'),
      primaryActionTooltip: i18n.tr('asmr_detail_action'),
      primaryActionIcon: Icons.info_outline_rounded,
      destructive: false,
      secondaryActionLabel: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_favorite_action',
      ),
      secondaryActionTooltip: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_add_favorite_tooltip',
      ),
      secondaryActionIcon: widget.work.isFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      tertiaryActionLabel: i18n.tr('asmr_download_action'),
      tertiaryActionTooltip: i18n.tr('asmr_download_work_tooltip'),
      verticalActions: true,
      onTertiaryAction: () => unawaited(_openDownloadPage(context)),
      onSecondaryAction: () => unawaited(_toggleFavorite(context)),
      onRemove: () => unawaited(showAsmrWorkDetailSheet(context, widget.work)),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.hardEdge,
        shape: cardShape,
        color: cs.surface,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            minTileHeight: _rootTileHeight,
            onExpansionChanged: (expanded) {
              if (_expanded == expanded) {
                return;
              }
              setState(() {
                _expanded = expanded;
              });
              if (expanded && tree == null && !isTreeLoading) {
                unawaited(
                  context.read<AsmrLibraryController>().ensureTrackTree(
                    widget.work,
                  ),
                );
              }
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            showTrailingIcon: false,
            tilePadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
            title: _AsmrRootCardContent(
              work: widget.work,
              expanded: _expanded,
              hasChildren: (visibleTree?.isNotEmpty ?? false) || isTreeLoading,
              onPlay: () => unawaited(_playWork(context)),
            ),
            children: [
              if (isTreeLoading && visibleTree == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: asmrBlue,
                    ),
                  ),
                )
              else if (visibleTree == null || visibleTree.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    i18n.tr('asmr_empty_track_tree'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                for (final node in visibleTree)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _AsmrTrackTreeNode(
                      work: widget.work,
                      node: node,
                      searchQuery: widget.searchQuery,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrRootCardContent extends StatelessWidget {
  const _AsmrRootCardContent({
    required this.work,
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
  });

  final AsmrWork work;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.watch<AppLanguageProvider>();
    return LibraryLikeFeaturedCardContent(
      title: work.title,
      lines: _workInfoLines(context, work),
      coverBuilder: (coverWidth) =>
          _AsmrWorkCover(url: _asmrWorkListCoverUrl(work), width: coverWidth),
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: true,
      playTooltip: i18n.tr('asmr_add_to_playlist'),
      accentColor: asmrBlue,
    );
  }
}

class _AsmrTrackTreeNode extends StatefulWidget {
  const _AsmrTrackTreeNode({
    required this.work,
    required this.node,
    required this.searchQuery,
  });

  final AsmrWork work;
  final AsmrTrackFile node;
  final String searchQuery;

  @override
  State<_AsmrTrackTreeNode> createState() => _AsmrTrackTreeNodeState();
}

class _AsmrTrackTreeNodeState extends State<_AsmrTrackTreeNode> {
  static const double _childFolderTileHeight = 62;
  static const double _childFolderTitleBlockHeight = 50;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.node.isFolder) {
      final visibleChildren = widget.node.children
          .where((child) => child.hasBrowsableContent)
          .toList(growable: false);
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final asmrBlue = isDark
          ? const Color(0xFF60A5FA)
          : const Color(0xFF1D4ED8);
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          controller: _expansionController,
          minTileHeight: _childFolderTileHeight,
          onExpansionChanged: (expanded) {
            if (_expanded == expanded) {
              return;
            }
            setState(() {
              _expanded = expanded;
            });
          },
          shape: const RoundedRectangleBorder(),
          collapsedShape: const RoundedRectangleBorder(),
          showTrailingIcon: false,
          tilePadding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
          title: Row(
            children: [
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: asmrBlue.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: _childFolderTitleBlockHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              height: 1.06,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          trailing: SizedBox(
            width: 62,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: () => unawaited(_playFolder(context)),
                  visualDensity: VisualDensity.compact,
                  tooltip: context.watch<AppLanguageProvider>().tr(
                    'asmr_add_to_playlist',
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: asmrBlue,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_circle_rounded, size: 25),
                ),
                const SizedBox(width: 2),
                if (visibleChildren.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IgnorePointer(
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          children: [
            for (final child in visibleChildren)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _AsmrTrackTreeNode(
                  work: widget.work,
                  node: child,
                  searchQuery: widget.searchQuery,
                ),
              ),
          ],
        ),
      );
    }
    return _AsmrTrackLeafRow(work: widget.work, node: widget.node);
  }

  Future<void> _playFolder(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final provider = context.read<AudioProvider>();
    final tracks = controller.buildPlayableTracksFromNode(
      widget.work,
      widget.node,
    );
    if (!context.mounted || tracks.isEmpty) {
      return;
    }
    await controller.recordHistory(widget.work);
    await provider.spawnSessionWithQueue(
      tracks,
      autoPlay: true,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': widget.node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrTrackLeafRow extends StatelessWidget {
  const _AsmrTrackLeafRow({required this.work, required this.node});

  final AsmrWork work;
  final AsmrTrackFile node;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Row(
          children: [
            Icon(
              Icons.audio_file_rounded,
              size: 16,
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                node.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: cs.onSurface,
                ),
              ),
            ),
            Text(
              _formatDuration(node.duration),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => unawaited(_playTrack(context)),
              style: IconButton.styleFrom(
                foregroundColor: asmrBlue,
                minimumSize: const Size(36, 36),
                maximumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.add_circle_rounded, size: 22),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playTrack(BuildContext context) async {
    await context.read<AsmrLibraryController>().playTrack(
      context.read<AudioProvider>(),
      work,
      node,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrWorkCover extends StatefulWidget {
  const _AsmrWorkCover({required this.url, required this.width});

  final String url;
  final double width;

  @override
  State<_AsmrWorkCover> createState() => _AsmrWorkCoverState();
}

class _AsmrWorkCoverState extends State<_AsmrWorkCover> {
  static const int _maxRetryCount = 3;
  int _retryCount = 0;
  Timer? _retryTimer;

  @override
  void didUpdateWidget(covariant _AsmrWorkCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryTimer?.cancel();
      _retryCount = 0;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleRetry() {
    if (_retryCount >= _maxRetryCount || _retryTimer?.isActive == true) {
      return;
    }
    final url = widget.url.trim();
    if (url.isEmpty) {
      return;
    }
    final attempt = _retryCount + 1;
    _retryTimer = Timer(Duration(milliseconds: 450 * attempt), () {
      if (!mounted) {
        return;
      }
      NetworkImage(url).evict().ignore();
      setState(() {
        _retryCount = attempt;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final width = widget.width;
    final height = width * 0.8;
    final url = widget.url.trim();
    return ClipRRect(
      clipBehavior: Clip.hardEdge,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? _AsmrCoverFallback(colorScheme: cs)
            : Image.network(
                url,
                key: ValueKey('$url#$_retryCount'),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) {
                    return child;
                  }
                  return _AsmrCoverLoading(colorScheme: cs);
                },
                errorBuilder: (_, _, _) {
                  _scheduleRetry();
                  return _AsmrCoverFallback(colorScheme: cs);
                },
              ),
      ),
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  for (final url in <String>[
    work.thumbnailUrl,
    work.mainCoverUrl,
    work.coverUrl,
  ]) {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

class _AsmrCoverLoading extends StatelessWidget {
  const _AsmrCoverLoading({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.92),
          ],
        ),
      ),
      child: Center(
        child: SizedBox.square(
          dimension: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _AsmrCoverFallback extends StatelessWidget {
  const _AsmrCoverFallback({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.92),
          ],
        ),
      ),
      child: Icon(
        Icons.photo_album_rounded,
        color: colorScheme.onPrimaryContainer,
        size: 28,
      ),
    );
  }
}

String _asmrCategoryLabelKey(AsmrCategoryType category) {
  return switch (category) {
    AsmrCategoryType.collected => 'asmr_category_collected',
    AsmrCategoryType.recommendation => 'asmr_category_recommendation',
    AsmrCategoryType.sales => 'asmr_category_sales',
    AsmrCategoryType.rating => 'asmr_category_rating',
    AsmrCategoryType.release => 'asmr_category_release',
    AsmrCategoryType.favorites => 'asmr_category_favorites',
    AsmrCategoryType.history => 'asmr_category_history',
  };
}

String _asmrLanguageLabelKey(AsmrContentLanguage language) {
  return switch (language) {
    AsmrContentLanguage.zh => 'asmr_language_zh',
    AsmrContentLanguage.ja => 'asmr_language_ja',
    AsmrContentLanguage.en => 'asmr_language_en',
  };
}

List<LibraryLikeInfoLineData> _workInfoLines(
  BuildContext context,
  AsmrWork work,
) {
  final i18n = context.read<AppLanguageProvider>();
  return <LibraryLikeInfoLineData>[
    if (work.rjCode.trim().isNotEmpty)
      LibraryLikeInfoLineData('RJ', work.rjCode),
    if (work.voiceActors.isNotEmpty)
      LibraryLikeInfoLineData('CV', work.voiceActors.join('、')),
    if (work.circleName.trim().isNotEmpty)
      LibraryLikeInfoLineData(
        i18n.tr('asmr_circle_label'),
        work.circleName.trim(),
      ),
    if (work.tags.isNotEmpty)
      LibraryLikeInfoLineData(
        i18n.tr('asmr_tags_label'),
        work.tags.join('、'),
        lines: shouldReserveTwoLibraryLikeInfoLines(work.tags.join('、'))
            ? 2
            : 1,
      ),
  ];
}

String _formatDuration(Duration value) {
  if (value == Duration.zero) {
    return '--:--';
  }
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

class _AsmrWorkSkeletonCard extends StatelessWidget {
  const _AsmrWorkSkeletonCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return Card(
      margin: EdgeInsets.zero,
      shape: cardShape,
      color: cs.surface,
      child: const Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: SizedBox(
          height: 136,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerContainer(width: 110, height: 136, borderRadius: 12),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 4),
                    ShimmerContainer(width: 90, height: 14, borderRadius: 4),
                    SizedBox(height: 12),
                    ShimmerContainer(width: 140, height: 14, borderRadius: 4),
                    SizedBox(height: 12),
                    ShimmerContainer(width: 110, height: 14, borderRadius: 4),
                    Spacer(),
                    ShimmerContainer(
                      width: double.infinity,
                      height: 26,
                      borderRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
