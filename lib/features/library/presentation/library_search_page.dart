part of 'library_tab.dart';

class _LibrarySearchPage extends ConsumerStatefulWidget {
  const _LibrarySearchPage();

  @override
  ConsumerState<_LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends ConsumerState<_LibrarySearchPage> {
  static const _searchCommitKey = 'library_search_page';

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selectedTagTerms = <String>{};
  final Set<String> _selectedVoiceActorTerms = <String>{};
  final Set<String> _selectedCircleTerms = <String>{};
  final Map<AudioLibraryCategoryType, String> _termSearchQueries = {};

  Timer? _debounceTimer;
  AudioLibraryCategoryType _categoryType = AudioLibraryCategoryType.all;
  bool _hasSwitchedCategory = false;
  String _query = '';

  FilteredLibraryTreeResult? _visibleSearchResult;
  String _visibleSearchQuery = '';
  int? _visibleSearchRevision;
  String? _pendingSearchKey;

  AudioLibraryCategorySnapshot? _lastCategoryFilterSnapshot;
  AudioLibraryCategoryType? _lastCategoryFilterType;
  String? _lastCategoryFilterKey;
  List<AudioLibraryCategoryEntry> _lastCategoryFilterResult = const [];
  final _coverWarmupScheduler = _LibraryCoverWarmupScheduler();

  String get _effectiveSearchQuery => _query;

  String get _termSearchQuery => _termSearchQueries[_categoryType] ?? '';

  set _termSearchQuery(String value) {
    if (value.isEmpty) {
      _termSearchQueries.remove(_categoryType);
    } else {
      _termSearchQueries[_categoryType] = value;
    }
  }

  void _setLocalState(VoidCallback fn) => setState(fn);

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
      setState(() {
        _query = query;
        _pendingSearchKey = null;
      });
      _jumpToTop();
    });
  }

  void _onSubmitted(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (_query != query) {
      setState(() {
        _query = query;
        _pendingSearchKey = null;
      });
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _jumpToTop();
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
      _pendingSearchKey = null;
    });
    _jumpToTop();
  }

  void _selectCategory(AudioLibraryCategoryType category) {
    if (_categoryType == category) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _categoryType = category;
      _hasSwitchedCategory = true;
    });
    _jumpToTop();
  }

  void _jumpToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _ensureFilteredSearchSnapshot({
    required LibraryFacade libraryFacade,
    required String query,
    required int structureRevision,
  }) {
    if ((_visibleSearchQuery == query &&
            _visibleSearchRevision == structureRevision) ||
        _pendingSearchKey == '$structureRevision|$query') {
      return;
    }
    final requestKey = '$structureRevision|$query';
    _pendingSearchKey = requestKey;
    final searchFuture = libraryFacade.loadLibraryTree().then((tree) {
      final request = LibrarySearchSnapshotRequest(
        tree: tree,
        query: query,
        structureRevision: structureRevision,
      );
      return libraryTreeTrackCount(tree) > 200
          ? compute(buildFilteredLibraryTreeSnapshot, request)
          : Future<FilteredLibraryTreeResult>.microtask(
              () => buildFilteredLibraryTreeSnapshot(request),
            );
    });
    unawaited(
      searchFuture.then((result) {
        if (!mounted || _pendingSearchKey != requestKey) return;
        UiInteractionCoordinator.instance.scheduleCommit(
          key: _searchCommitKey,
          priority: 5,
          commit: () {
            if (!mounted || _pendingSearchKey != requestKey) return;
            setState(() {
              _visibleSearchResult = result;
              _visibleSearchQuery = query;
              _visibleSearchRevision = structureRevision;
              _pendingSearchKey = null;
            });
          },
        );
      }),
    );
  }

  void _scheduleLibraryCoverWarmup({
    required Iterable<MusicTrack?> tracks,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
    String scope = '',
  }) {
    _coverWarmupScheduler.schedule(
      controller: ref.read(libraryCoverUiControllerProvider),
      canCommit: () => mounted,
      tracks: tracks,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
      coverGeneration: coverGeneration,
      scope: scope,
    );
  }

  Iterable<MusicTrack?> _coverWarmupTracks(Iterable<LibraryNode> nodes) sync* {
    for (final node in nodes.take(12)) {
      if (node is TrackNode) {
        yield node.track;
      } else if (node is FolderNode) {
        yield node.firstTrack;
      }
    }
  }

  Widget _buildAllResults({
    required LibraryFacade libraryFacade,
    required AppLanguageProvider i18n,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
    required bool cardPositionsLocked,
  }) {
    _ensureFilteredSearchSnapshot(
      libraryFacade: libraryFacade,
      query: _query,
      structureRevision: structureRevision,
    );
    final result =
        _visibleSearchQuery == _query &&
            _visibleSearchRevision == structureRevision
        ? _visibleSearchResult
        : null;
    final tree = result?.tree;
    final Widget content;
    if (tree == null) {
      content = const SizedBox.shrink();
    } else if (tree.isEmpty) {
      content = AppEmptyState(
        key: const ValueKey<String>('library_search_empty'),
        icon: _query.isEmpty
            ? Icons.library_music_outlined
            : Icons.search_off_rounded,
        title: i18n.tr(_query.isEmpty ? 'no_audio_files' : 'no_search_results'),
        message: i18n.tr(
          _query.isEmpty ? 'import_audio_hint' : 'search_try_another_term',
        ),
      );
    } else {
      _scheduleLibraryCoverWarmup(
        tracks: _coverWarmupTracks(tree),
        structureRevision: structureRevision,
        detailRevision: detailRevision,
        coverGeneration: coverGeneration,
        scope: 'search_all',
      );
      content = ListView.builder(
        key: const ValueKey<String>('library_search_results_all'),
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          16,
          AppSearchPageScaffold.controlsTopInset(context),
          16,
          MediaQuery.paddingOf(context).bottom + 16,
        ),
        cacheExtent: 320,
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: tree.length,
        itemBuilder: (context, index) {
          final node = tree[index];
          return RepaintBoundary(
            key: ValueKey<String>('search_${node.path}'),
            child: _LibraryTreeItem(
              node: node,
              searchQuery: _query,
              cardPositionsLocked: cardPositionsLocked,
            ),
          );
        },
      );
    }
    return PlaceholderContentTransition(
      showPlaceholder: result == null,
      placeholder: _LibraryLoadingSkeleton(
        bottomInset: 16,
        topInset: AppSearchPageScaffold.controlsTopInset(context),
      ),
      content: content,
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_searchCommitKey);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final structureRevision = ref.watch(
      libraryListUiProvider.select((state) => state.structureRevision),
    );
    final detailRevision = ref.watch(libraryDetailRevisionProvider);
    final coverGeneration = ref.watch(coverGenerationProvider);
    final settings = ref.watch(settingsStateProvider).value ?? SettingsState();
    final cardPositionsLocked = settings.cardPositionsLocked;
    final categories = <AppSearchCategory<AudioLibraryCategoryType>>[
      AppSearchCategory(
        value: AudioLibraryCategoryType.all,
        label: i18n.tr('library_category_all'),
      ),
      AppSearchCategory(
        value: AudioLibraryCategoryType.tags,
        label: i18n.tr('library_category_tags'),
      ),
      AppSearchCategory(
        value: AudioLibraryCategoryType.voiceActors,
        label: i18n.tr('library_category_voice_actors'),
      ),
      AppSearchCategory(
        value: AudioLibraryCategoryType.circles,
        label: i18n.tr('library_category_circles'),
      ),
    ];

    final Widget body;
    if (_categoryType == AudioLibraryCategoryType.all) {
      body = _buildAllResults(
        libraryFacade: libraryFacade,
        i18n: i18n,
        structureRevision: structureRevision,
        detailRevision: detailRevision,
        coverGeneration: coverGeneration,
        cardPositionsLocked: cardPositionsLocked,
      );
    } else {
      body = _buildCategoryBody(
        libraryFacade: libraryFacade,
        i18n: i18n,
        topPadding: AppSearchPageScaffold.controlsTopInset(context),
        bottomPadding: MediaQuery.paddingOf(context).bottom + 16,
        cacheExtent: 320,
        structureRevision: structureRevision,
        detailRevision: detailRevision,
        coverGeneration: coverGeneration,
      );
    }

    return AppSearchPageScaffold<AudioLibraryCategoryType>(
      controller: _controller,
      focusNode: _focusNode,
      hintText: i18n.tr('search_audio_placeholder'),
      categories: categories,
      selectedCategory: _categoryType,
      onCategorySelected: _selectCategory,
      onChanged: _onChanged,
      onSubmitted: _onSubmitted,
      onCloseOrClear: _closeOrClear,
      blurEnabled: settings.uiBlurEffectEnabled,
      body: body,
    );
  }
}
