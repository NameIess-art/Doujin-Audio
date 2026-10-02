part of 'asmr_tab.dart';

class _AsmrSearchPage extends ConsumerStatefulWidget {
  const _AsmrSearchPage();

  @override
  ConsumerState<_AsmrSearchPage> createState() => _AsmrSearchPageState();
}

class _AsmrSearchPageState extends ConsumerState<_AsmrSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final Map<AsmrCategoryType, ScrollController> _scrollControllers = {
    for (final category in kAsmrSelectableCategories)
      category: ScrollController(),
  };
  Timer? _debounceTimer;
  AsmrCategoryType _category = AsmrCategoryType.collected;
  String _query = '';
  bool _showSearchPlaceholder = false;
  bool _isSelectionMode = false;
  final Set<int> _selectedWorkIds = <int>{};
  int _requestSerial = 0;
  late final AppLanguageProvider _languageProvider;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(browsePageStateStoreProvider).stateFor(_stateKey);
    _query = saved['query'] as String? ?? '';
    _controller.text = _query;
    final category = saved['category'];
    if (category is String) {
      final restored = kAsmrSelectableCategories.where(
        (value) => value.name == category,
      );
      if (restored.isNotEmpty) _category = restored.first;
    }
    _languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _languageProvider.addListener(_handleLanguageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  String get _stateKey =>
      'asmr_search:${ref.read(asmrLibraryControllerProvider)?.browseCacheScope ?? ''}';
  void _saveSearchState() => ref.read(browsePageStateStoreProvider).update(
    _stateKey,
    {'category': _category.name, 'query': _query},
  );

  void _handleLanguageChanged() {
    if (!mounted) return;
    ref
        .read(asmrLibraryControllerProvider)
        ?.setPageLanguage(_languageProvider.language);
    unawaited(_refresh());
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
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
    _saveSearchState();
    final query = _query;
    final category = _category;
    final requestSerial = ++_requestSerial;
    setState(() {
      final cached = ref
          .read(asmrLibraryControllerProvider)
          ?.categoryViewState(category, searchQuery: query);
      _showSearchPlaceholder =
          showSearchPlaceholder &&
          query.isNotEmpty &&
          !(cached?.hasAttemptedLoad ?? false);
    });
    final controller = ref.read(asmrLibraryControllerProvider);
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
          ? controller.refreshCategory(category, searchQuery: query)
          : controller.ensureCategoryLoaded(category, searchQuery: query),
    );
    if (!mounted || requestSerial != _requestSerial) return;
    setState(() => _showSearchPlaceholder = false);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
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
        (state) => state.value?.uiBlurEffectEnabled ?? true,
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
    final body = _AsmrCategoryList(
      key: ValueKey<String>('asmr_search_${_category.name}'),
      isActive: true,
      category: _category,
      isLoadPending: _showSearchPlaceholder,
      scrollController: _scrollControllers[_category]!,
      searchQuery: _query,
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
