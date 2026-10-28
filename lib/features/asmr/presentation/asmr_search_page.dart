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
  final ScrollController _suggestionsScrollController = ScrollController();
  late final ValueNotifier<int> _activeCategoryIndex;
  String _query = '';
  final ValueNotifier<String> _inputQuery = ValueNotifier('');
  Set<String> _selectedQueryTerms = const {};
  late final ValueNotifier<(AsmrSearchSuggestions?, Object?)> _suggestions;
  late final Listenable _suggestionChanges;
  bool _showSearchPlaceholder = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedWorkIds = <String>{};
  int _requestSerial = 0;
  bool _refreshPending = false;
  ModalRoute<dynamic>? _route;
  late final String _refreshCommitKey =
      'asmr_search_refresh_${identityHashCode(this)}';
  late final AppLanguageProvider _languageProvider;
  AsmrLibraryController? _searchController;

  AsmrCategoryType get _category =>
      kAsmrSelectableCategories[_activeCategoryIndex.value];

  @override
  void initState() {
    super.initState();
    final initialIndex = kAsmrSelectableCategories.indexOf(
      widget.initialCategory,
    );
    _activeCategoryIndex = ValueNotifier<int>(
      initialIndex >= 0 ? initialIndex : 0,
    );
    _searchController = ref.read(asmrLibraryControllerProvider);
    _suggestions = ValueNotifier((
      _searchController?.searchSuggestions,
      _searchController?.searchSuggestionsError,
    ));
    _suggestionChanges = Listenable.merge([_inputQuery, _suggestions]);
    _searchController?.addListener(_handleSuggestionsChanged);
    _searchController?.beginSearchSession();
    _languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _languageProvider.addListener(_handleLanguageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_searchController?.ensureSearchSuggestions());
    });
  }

  void _handleLanguageChanged() {
    if (!mounted) return;
    _scheduleRefresh();
  }

  void _handleSuggestionsChanged() {
    // Catalog, playback, and account notifications do not affect these chips.
    _suggestions.value = (
      _searchController?.searchSuggestions,
      _searchController?.searchSuggestionsError,
    );
  }

  bool _isSuggestionSelected(String value) {
    final terms = normalizedSearchTerms(value);
    return terms.isNotEmpty && terms.every(_selectedQueryTerms.contains);
  }

  void _resetScroll() {
    final controller = _scrollControllers[_category]!;
    if (controller.hasClients) controller.jumpTo(0);
  }

  void _onChanged(String value) {
    final input = canonicalSearchQuery(value);
    final needsPageBuild =
        _query.isNotEmpty || _inputQuery.value.isEmpty != input.isEmpty;
    UiInteractionCoordinator.instance.cancelCommit(_refreshCommitKey);
    _refreshPending = false;
    if (_query.isNotEmpty) {
      _searchController?.setSearchQuery('', _category);
      _resetScroll();
    }
    void updateDraft() {
      _selectedQueryTerms = normalizedSearchTerms(input).toSet();
      _inputQuery.value = input;
      _query = '';
      _requestSerial++;
      _showSearchPlaceholder = false;
      _clearSelection();
    }

    if (needsPageBuild) {
      setState(updateDraft);
    } else {
      updateDraft();
    }
  }

  void _toggleSuggestion(String value) {
    final query = toggleSearchQueryTerms(_controller.text, value);
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _onChanged(query);
  }

  Future<void> _onSubmitted(String value) async {
    final query = canonicalSearchQuery(value);
    if (query.isEmpty) return;
    final current = _searchController?.categoryViewState(
      _category,
      searchQuery: query,
      searchSession: true,
    );
    if (_query == query &&
        (_refreshPending ||
            current?.isLoading == true ||
            current?.isRefreshing == true)) {
      return;
    }
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _selectedQueryTerms = normalizedSearchTerms(query).toSet();
    _inputQuery.value = query;
    _searchController?.setSearchQuery(query, _category);
    _resetScroll();
    setState(() {
      _query = query;
      _clearSelection();
    });
    FocusManager.instance.primaryFocus?.unfocus();
    _scheduleRefresh(showSearchPlaceholder: true);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .recordSearchQuery(query, online: true);
    } catch (error, stack) {
      AppLogService.warning(
        'asmr_search_history_save_failed',
        error: error,
        stackTrace: stack,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
      );
    }
  }

  void _closeOrClear() {
    if (_controller.text.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _controller.clear();
    _onChanged('');
  }

  void _selectCategory(AsmrCategoryType category) {
    if (_category == category) return;
    final outgoingScroll = _scrollControllers[_category]!;
    if (outgoingScroll.hasClients) outgoingScroll.jumpTo(outgoingScroll.offset);
    if (_isSelectionMode) setState(_clearSelection);
    final targetIndex = kAsmrSelectableCategories.indexOf(category);
    if (targetIndex >= 0) _activeCategoryIndex.value = targetIndex;
    if (_query.isNotEmpty) {
      _searchController?.setSearchQuery(_query, category);
      _scheduleRefresh(showSearchPlaceholder: true);
    }
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
        ..add(work.workKey);
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(_clearSelection);
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
      onFinished: (failedIds) => setState(() {
        _selectedWorkIds
          ..clear()
          ..addAll(failedIds);
        _isSelectionMode = failedIds.isNotEmpty;
      }),
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

  void _scheduleRefresh({bool showSearchPlaceholder = false}) {
    if (_query.isEmpty) return;
    _requestSerial++;
    _refreshPending = true;
    if (showSearchPlaceholder) {
      final cached = ref
          .read(asmrLibraryControllerProvider)
          ?.categoryViewState(
            _category,
            searchQuery: _query,
            searchSession: true,
          );
      final pending = _query.isNotEmpty && !(cached?.hasAttemptedLoad ?? false);
      if (_showSearchPlaceholder != pending) {
        setState(() => _showSearchPlaceholder = pending);
      }
    }
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _refreshCommitKey,
      commit: () {
        if (!mounted || _route?.isCurrent == false) return;
        ref
            .read(asmrLibraryControllerProvider)
            ?.setPageLanguage(_languageProvider.language);
        unawaited(_refresh(showSearchPlaceholder: showSearchPlaceholder));
      },
    );
  }

  Future<void> _refresh({
    bool showSearchPlaceholder = false,
    bool force = false,
  }) async {
    UiInteractionCoordinator.instance.cancelCommit(_refreshCommitKey);
    _refreshPending = false;
    final query = _query;
    if (query.isEmpty) return;
    final category = _category;
    final controller = ref.read(asmrLibraryControllerProvider);
    final cached = controller?.categoryViewState(
      category,
      searchQuery: query,
      searchSession: true,
    );
    final requestInProgress =
        cached?.isLoading == true || cached?.isRefreshing == true;
    if (requestInProgress && !showSearchPlaceholder) return;
    final requestSerial = ++_requestSerial;
    final pending =
        showSearchPlaceholder &&
        query.isNotEmpty &&
        !(cached?.hasAttemptedLoad ?? false);
    if (_showSearchPlaceholder != pending) {
      setState(() => _showSearchPlaceholder = pending);
    }
    final retryFailedQuery =
        cached?.hasAttemptedLoad == true && cached?.lastError != null;
    if (!requestInProgress &&
        !force &&
        !retryFailedQuery &&
        (cached?.hasAttemptedLoad ?? false)) {
      return;
    }
    if (controller == null) {
      if (mounted &&
          requestSerial == _requestSerial &&
          _showSearchPlaceholder) {
        setState(() => _showSearchPlaceholder = false);
      }
      return;
    }
    final language = ref.read(appLanguageProviderInstanceProvider).language;
    await controller.initialize(
      defaultLanguage: AsmrContentLanguage.fromAppLanguageName(language.name),
    );
    if (!mounted || requestSerial != _requestSerial) return;
    if (!force && UiInteractionCoordinator.instance.isInteracting) {
      _scheduleRefresh(showSearchPlaceholder: showSearchPlaceholder);
      return;
    }
    await UiOperationService.instance.run<void>(
      scope: UiOperationScope.asmrCategory(
        AsmrOperationKind.refresh,
        category.name,
      ),
      labelKey: 'loading_dot',
      task: (_) => !requestInProgress && (force || retryFailedQuery)
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
    if (_showSearchPlaceholder) {
      setState(() => _showSearchPlaceholder = false);
    }
  }

  Widget _buildSuggestions(
    AppLanguageProvider i18n,
    Color accent,
    double topInset,
    double bottomInset,
  ) {
    return Consumer(
      builder: (context, ref, _) {
        final history =
            ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.asmrSearchHistory,
              ),
            ) ??
            ref.read(settingsRepositoryProvider).slice.state.asmrSearchHistory;
        return ListenableBuilder(
          listenable: _suggestionChanges,
          builder: (context, _) {
            final (suggestions, error) = _suggestions.value;
            final errorText = error == null
                ? null
                : localizedAsmrCatalogErrorText(i18n, error);
            return PageHeaderInset(
              topInset: topInset,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: DragOnlyScrollbar(
                  controller: _suggestionsScrollController,
                  thumbVisibility:
                      defaultTargetPlatform == TargetPlatform.windows,
                  child: CustomScrollView(
                    key: const ValueKey('asmr_search_suggestions'),
                    controller: _suggestionsScrollController,
                    slivers: [
                      SliverToBoxAdapter(child: SizedBox(height: topInset)),
                      AppSearchSuggestionSection(
                        key: const ValueKey('asmr_search_history'),
                        title: i18n.tr('search_history'),
                        items: history,
                        onClear: () => unawaited(
                          clearSearchHistoryWithFeedback(context, online: true),
                        ),
                        clearLabel: i18n.tr('clear'),
                        isSelected: _isSuggestionSelected,
                        onToggle: _toggleSuggestion,
                        emptyText: i18n.tr('search_history_empty'),
                        expandLabel: i18n.tr('expand'),
                        collapseLabel: i18n.tr('collapse'),
                        accentColor: accent,
                      ),
                      AppSearchSuggestionSection(
                        key: const ValueKey('asmr_search_voice_actors'),
                        title: i18n.tr('search_hot_voice_actors'),
                        items: suggestions?.voiceActors ?? const [],
                        maxExpandedItems: AsmrSearchSuggestions.displayLimit,
                        isSelected: _isSuggestionSelected,
                        onToggle: _toggleSuggestion,
                        emptyText: i18n.tr('no_search_results'),
                        expandLabel: i18n.tr('expand'),
                        collapseLabel: i18n.tr('collapse'),
                        accentColor: accent,
                        errorText: errorText,
                        retryLabel: i18n.tr('retry'),
                        onRetry: () => unawaited(
                          _searchController?.ensureSearchSuggestions(
                            force: true,
                          ),
                        ),
                      ),
                      AppSearchSuggestionSection(
                        key: const ValueKey('asmr_search_tags'),
                        title: i18n.tr('search_hot_tags'),
                        items: suggestions?.tags ?? const [],
                        maxExpandedItems: AsmrSearchSuggestions.displayLimit,
                        isSelected: _isSuggestionSelected,
                        onToggle: _toggleSuggestion,
                        emptyText: i18n.tr('no_search_results'),
                        expandLabel: i18n.tr('expand'),
                        collapseLabel: i18n.tr('collapse'),
                        accentColor: accent,
                        errorText: errorText,
                        retryLabel: i18n.tr('retry'),
                        onRetry: () => unawaited(
                          _searchController?.ensureSearchSuggestions(
                            force: true,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_refreshCommitKey);
    _activeCategoryIndex.dispose();
    _suggestionsScrollController.dispose();
    _searchController?.removeListener(_handleSuggestionsChanged);
    _suggestions.dispose();
    _inputQuery.dispose();
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
    final categories = kAsmrSelectableCategories
        .map(
          (category) => AppSearchCategory<AsmrCategoryType>(
            value: category,
            label: i18n.tr(_asmrCategoryLabelKey(category)),
          ),
        )
        .toList(growable: false);
    final topInset = _isSelectionMode
        ? AppPageHeaderMetrics.expandedToolbarHeight +
              MediaQuery.paddingOf(context).top +
              AppPageHeaderMetrics.bottomSpacing
        : AppSearchPageScaffold.controlsTopInset(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom + 96;
    final resultsBody = _query.isEmpty
        ? null
        : AppFadeThroughIndexedStack.lazy(
            key: const ValueKey<String>('asmr_search_category_stack'),
            indexListenable: _activeCategoryIndex,
            itemCount: kAsmrSelectableCategories.length,
            contentRevision: (
              _query,
              i18n.language,
              _showSearchPlaceholder,
              _isSelectionMode,
              _selectedWorkIds.join(','),
              topInset,
              bottomInset,
            ),
            itemBuilder: (context, index) {
              final category = kAsmrSelectableCategories[index];
              return _AsmrCategoryList(
                key: ValueKey<String>('asmr_search_${category.name}'),
                isActive: () => category == _category,
                isPageActive: () => _query.isNotEmpty,
                category: category,
                isLoadPending: _showSearchPlaceholder,
                scrollController: _scrollControllers[category]!,
                searchQuery: _query,
                searchSession: true,
                topInset: topInset,
                bottomInset: bottomInset,
                onRefresh: () => _refresh(force: true),
                isSelectionMode: _isSelectionMode,
                selectedWorkIds: _selectedWorkIds,
                onEnterSelectionMode: _enterSelectionMode,
                onToggleSelection: _toggleWorkSelection,
              );
            },
          );
    final page = ValueListenableBuilder<int>(
      valueListenable: _activeCategoryIndex,
      child: resultsBody,
      builder: (context, _, resultsBody) {
        final selectedWorks = _isSelectionMode
            ? _selectedWorks()
            : <AsmrWork>[];
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
          accentColor: accent,
          showConfirmButton: _query.isEmpty,
          confirmLabel: i18n.tr('confirm'),
          onConfirm: _inputQuery.value.isEmpty
              ? null
              : () => unawaited(_onSubmitted(_controller.text)),
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
          body: Builder(
            builder: (_) =>
                _buildSuggestions(i18n, accent, topInset, bottomInset),
          ),
          resultsBody: resultsBody,
        );
      },
    );
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        if (_refreshPending && _route?.isCurrent != false) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_refreshPending || _route?.isCurrent == false) {
              return;
            }
            _scheduleRefresh(showSearchPlaceholder: _showSearchPlaceholder);
          });
        }
        return page;
      },
    );
  }
}
