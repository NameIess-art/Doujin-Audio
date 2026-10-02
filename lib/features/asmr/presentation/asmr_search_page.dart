part of 'asmr_tab.dart';

class _AsmrSearchPage extends ConsumerStatefulWidget {
  const _AsmrSearchPage({required this.initialCategory});

  final AsmrCategoryType initialCategory;

  @override
  ConsumerState<_AsmrSearchPage> createState() => _AsmrSearchPageState();
}

class _AsmrSearchPageState extends ConsumerState<_AsmrSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final Map<AsmrCategoryType, ScrollController> _scrollControllers = {
    for (final category in kAsmrSelectableCategories)
      category: ScrollController(keepScrollOffset: false),
  };
  Timer? _debounceTimer;
  late AsmrCategoryType _category;
  late final ValueNotifier<int> _activeCategoryIndex;
  late final Set<AsmrCategoryType> _visitedCategories;
  String _query = '';
  bool _showSearchPlaceholder = false;
  bool _isSelectionMode = false;
  final Set<int> _selectedWorkIds = <int>{};
  int _requestSerial = 0;
  late final AppLanguageProvider _languageProvider;
  AsmrLibraryController? _searchController;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    final initialIndex = kAsmrSelectableCategories.indexOf(_category);
    _activeCategoryIndex = ValueNotifier<int>(
      initialIndex >= 0 ? initialIndex : 0,
    );
    _visitedCategories = <AsmrCategoryType>{_category};
    _searchController = ref.read(asmrLibraryControllerProvider);
    _searchController?.beginSearchSession();
    _languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _languageProvider.addListener(_handleLanguageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  void _handleLanguageChanged() {
    if (!mounted) return;
    ref
        .read(asmrLibraryControllerProvider)
        ?.setPageLanguage(_languageProvider.language);
    unawaited(_refresh());
  }

  void _resetScroll() {
    final controller = _scrollControllers[_category]!;
    if (controller.hasClients) controller.jumpTo(0);
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
      _resetScroll();
      setState(() {
        _query = query;
        _clearSelection();
      });
      unawaited(_refresh(showSearchPlaceholder: query.isNotEmpty));
    });
  }

  Future<void> _onSubmitted(String value) async {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (_query != query) {
      _resetScroll();
      setState(() {
        _query = query;
        _clearSelection();
      });
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _refresh(showSearchPlaceholder: query.isNotEmpty);
  }

  void _closeOrClear() {
    if (_controller.text.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _debounceTimer?.cancel();
    _controller.clear();
    _resetScroll();
    setState(() {
      _query = '';
      _showSearchPlaceholder = false;
      _requestSerial += 1;
      _clearSelection();
    });
    unawaited(_refresh());
  }

  void _selectCategory(AsmrCategoryType category) {
    if (_category == category) return;
    _visitedCategories.add(category);
    final targetIndex = kAsmrSelectableCategories.indexOf(category);
    if (targetIndex >= 0) {
      _activeCategoryIndex.value = targetIndex;
    }
    setState(() {
      _category = category;
      _clearSelection();
    });
    unawaited(_refresh(showSearchPlaceholder: _query.isNotEmpty));
  }

  void _clearSelection() {
    _isSelectionMode = false;
    _selectedWorkIds.clear();
  }

  void _enterSelectionMode(AsmrWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedWorkIds
        ..clear()
        ..add(work.id);
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(_clearSelection);
  }

  void _toggleWorkSelection(AsmrWork work) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (!_selectedWorkIds.add(work.id)) {
        _selectedWorkIds.remove(work.id);
        if (_selectedWorkIds.isEmpty) _isSelectionMode = false;
      }
    });
  }

  List<AsmrWork> _selectedWorks() => _selectedAsmrWorks(
    ref,
    category: _category,
    searchQuery: _query,
    searchSession: true,
    selectedWorkIds: _selectedWorkIds,
  );

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

  Future<void> _refresh({
    bool showSearchPlaceholder = false,
    bool force = false,
  }) async {
    final query = _query;
    final category = _category;
    final requestSerial = ++_requestSerial;
    final controller = ref.read(asmrLibraryControllerProvider);
    final cached = controller?.categoryViewState(
      category,
      searchQuery: query,
      searchSession: true,
    );
    setState(() {
      _showSearchPlaceholder =
          showSearchPlaceholder &&
          query.isNotEmpty &&
          !(cached?.hasAttemptedLoad ?? false);
    });
    if (!force && (cached?.hasAttemptedLoad ?? false)) return;
    if (controller == null) {
      if (mounted && requestSerial == _requestSerial) {
        setState(() => _showSearchPlaceholder = false);
      }
      return;
    }
    final language = ref.read(appLanguageProviderInstanceProvider).language;
    await controller.initialize(
      defaultLanguage: AsmrContentLanguage.fromAppLanguageName(language.name),
    );
    if (!mounted || requestSerial != _requestSerial) return;
    await UiOperationService.instance.run<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: (_) => force
          ? controller.refreshCategory(
              category,
              searchQuery: query,
              searchSession: true,
            )
          : controller.ensureCategoryLoaded(
              category,
              searchQuery: query,
              searchSession: true,
            ),
    );
    if (!mounted || requestSerial != _requestSerial) return;
    setState(() => _showSearchPlaceholder = false);
  }

  @override
  void dispose() {
    _activeCategoryIndex.dispose();
    _debounceTimer?.cancel();
    _searchController?.endSearchSession();
    _languageProvider.removeListener(_handleLanguageChanged);
    _controller.dispose();
    _focusNode.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final accent = AppDesignTokens.of(context).asmrAccent;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.uiBlurEffectEnabled ?? false,
      ),
    );
    final categories = kAsmrSelectableCategories
        .map(
          (category) => AppSearchCategory<AsmrCategoryType>(
            value: category,
            label: i18n.tr(_asmrCategoryLabelKey(category)),
          ),
        )
        .toList(growable: false);
    final body = AppFadeThroughIndexedStack(
      key: const ValueKey<String>('asmr_search_category_stack'),
      indexListenable: _activeCategoryIndex,
      style: AppIndexedStackTransitionStyle.slide,
      duration: kAppMotionSlow,
      children: [
        for (final category in kAsmrSelectableCategories)
          if (_visitedCategories.contains(category))
            _AsmrCategoryList(
              key: ValueKey<String>('asmr_search_${category.name}'),
              isActive: category == _category,
              category: category,
              isLoadPending: _showSearchPlaceholder,
              scrollController: _scrollControllers[category]!,
              searchQuery: _query,
              searchSession: true,
              topInset: _isSelectionMode
                  ? AppPageHeaderMetrics.expandedToolbarHeight +
                        MediaQuery.paddingOf(context).top +
                        AppPageHeaderMetrics.bottomSpacing
                  : AppSearchPageScaffold.controlsTopInset(context),
              bottomInset: MediaQuery.paddingOf(context).bottom + 16,
              onRefresh: () => _refresh(force: true),
              isSelectionMode: _isSelectionMode,
              selectedWorkIds: _selectedWorkIds,
              onEnterSelectionMode: _enterSelectionMode,
              onToggleSelection: _toggleWorkSelection,
            )
          else
            const SizedBox.shrink(),
      ],
    );
    final selectedWorks = _selectedWorks();
    return AppSearchPageScaffold<AsmrCategoryType>(
      controller: _controller,
      focusNode: _focusNode,
      hintText: i18n.tr('asmr_search_hint'),
      categories: categories,
      selectedCategory: _category,
      onCategorySelected: _selectCategory,
      onChanged: _onChanged,
      onSubmitted: (value) => unawaited(_onSubmitted(value)),
      onCloseOrClear: _closeOrClear,
      blurEnabled: blurEnabled,
      accentColor: accent,
      controlsOverlay: _isSelectionMode
          ? Theme(
              data: asmrThemeData(context),
              child: _AsmrBatchSelectionHeader(
                keyPrefix: 'asmr_search',
                i18n: i18n,
                selectedWorks: selectedWorks,
                onAddToPlaylist: selectedWorks.isEmpty
                    ? null
                    : _addSelectedWorksToPlaylist,
                onDownload: selectedWorks.isEmpty
                    ? null
                    : _downloadSelectedWorks,
                onToggleFavorite: selectedWorks.isEmpty
                    ? null
                    : _toggleSelectedFavorites,
                onExit: _exitSelectionMode,
              ),
            )
          : null,
      body: body,
    );
  }
}
