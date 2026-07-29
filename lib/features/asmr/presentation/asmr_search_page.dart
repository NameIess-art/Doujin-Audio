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
  bool _loadPending = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
      setState(() => _query = query);
      unawaited(_refresh());
    });
  }

  Future<void> _onSubmitted(String value) async {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (_query != query) setState(() => _query = query);
    FocusManager.instance.primaryFocus?.unfocus();
    await _refresh();
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
      _loadPending = false;
      _requestSerial += 1;
    });
    unawaited(_refresh());
  }

  void _selectCategory(AsmrCategoryType category) {
    if (_category == category) return;
    setState(() => _category = category);
    final controller = _scrollControllers[category];
    if (controller != null && controller.hasClients) controller.jumpTo(0);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final query = _query;
    final requestSerial = ++_requestSerial;
    setState(() => _loadPending = true);
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) {
      if (mounted && requestSerial == _requestSerial) {
        setState(() => _loadPending = false);
      }
      return;
    }
    final language = ref.read(appLanguageProviderInstanceProvider).language;
    await controller.initialize(
      defaultLanguage: AsmrContentLanguage.fromAppLanguageName(language.name),
    );
    await UiOperationService.instance.run<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        _category.name,
      ),
      labelKey: 'loading_dot',
      task: (_) => controller.refreshCategory(_category, searchQuery: query),
    );
    if (!mounted || requestSerial != _requestSerial) return;
    setState(() => _loadPending = false);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
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
      category: _category,
      isLoadPending: _loadPending,
      scrollController: _scrollControllers[_category]!,
      searchQuery: _query,
      topInset: AppSearchPageScaffold.controlsTopInset(context),
      bottomInset: MediaQuery.paddingOf(context).bottom + 16,
      onRefresh: _refresh,
    );
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
      body: body,
    );
  }
}
