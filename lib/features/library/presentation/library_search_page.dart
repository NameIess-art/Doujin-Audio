import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../player/application/playback_subtitle_service.dart';
import '../../player/presentation/playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/library_facade.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import 'audio_detail_sheet.dart' show showAudioDetailEditor;
import 'library_providers.dart';
import 'library_search_all_results.dart';
import 'library_tab_ui_helpers.dart';
import 'library_view_models.dart';

class LibrarySearchPage extends ConsumerStatefulWidget {
  const LibrarySearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

typedef _SelectionTreeKey = (int, SearchFilters, int, int, int);

class _LibrarySearchPageState extends ConsumerState<LibrarySearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _draftQuery = ValueNotifier<String>('');
  final _suggestionSelection = ValueNotifier<_LibrarySuggestionSelection>(
    const _LibrarySuggestionSelection(),
  );
  final _resultsScrollController = WindowsSmoothScrollController(
    keepScrollOffset: false,
  );
  final _suggestionsScrollController = WindowsSmoothScrollController(
    keepScrollOffset: false,
  );
  final _searchIndex = LibrarySearchIndex();
  PlaybackSubtitleService? _observedSubtitleService;
  int? _observedAvailabilityRevision;
  int _subtitleRevision = 0;
  SearchElements? _parsedDraftElements = emptySearchElements;
  String _canonicalDraftQuery = '';
  SearchElements? _parsedSubmittedElements;
  String? _submittedQuery;
  SearchFilters _filters = emptySearchFilters;
  bool _matchAll = true;
  int _queryRevision = 0;
  bool _isSelectionMode = false;
  Set<String> _selectedLibraryPaths = const {};
  (_SelectionTreeKey, List<LibraryNode>)? _searchSelection;
  Future<AudioLibraryCategorySnapshot>? _categorySnapshotFuture;
  int? _categorySnapshotStructureRevision;
  int? _categorySnapshotDetailRevision;

  bool _canSubmitElements(SearchElements? elements, SearchFilters filters) =>
      elements != null &&
      (elements.all.isNotEmpty ||
          elements.any.isNotEmpty ||
          filters != emptySearchFilters);

  bool get _canSubmitDraft =>
      _canSubmitElements(_parsedDraftElements, _filters);

  void _syncSuggestionSelection({bool allowDuringComposing = false}) {
    if (!allowDuringComposing) {
      final composing = _controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return;
    }
    final elements = _parsedDraftElements;
    final selected = _matchAll ? elements?.all : elements?.any;
    final selectedLower = selected == null || selected.isEmpty
        ? const <String>{}
        : <String>{for (final term in selected) term.toLowerCase()};
    final next = _LibrarySuggestionSelection(
      canonicalDraft: _canonicalDraftQuery,
      selectedLowerTerms: selectedLower,
    );
    if (_suggestionSelection.value != next) {
      _suggestionSelection.value = next;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    if (widget.initialQuery.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onSubmitted(legacySearchElements(widget.initialQuery));
    });
  }

  void _handleControllerChanged() {
    if (_controller.text != _draftQuery.value) return;
    final composing = _controller.value.composing;
    if (!composing.isValid || composing.isCollapsed) {
      _syncSuggestionSelection();
    }
  }

  void _handleSubtitlesChanged() {
    final availabilityRevision = _observedSubtitleService?.availabilityRevision;
    if (availabilityRevision == _observedAvailabilityRevision) return;
    _observedAvailabilityRevision = availabilityRevision;
    _searchIndex.invalidateSubtitleCache();
    if (!mounted) return;
    if (_submittedQuery != null && _filters.hasSubtitle != null) {
      setState(() => _subtitleRevision++);
    }
  }

  void _observeSubtitleService(PlaybackSubtitleService subtitles) {
    if (identical(_observedSubtitleService, subtitles)) return;
    final previous = _observedSubtitleService;
    if (previous != null) {
      previous.removeListener(_handleSubtitlesChanged);
      _searchIndex.invalidateSubtitleCache();
      _subtitleRevision++;
    }
    _observedSubtitleService = subtitles;
    _observedAvailabilityRevision = subtitles.availabilityRevision;
    subtitles.addListener(_handleSubtitlesChanged);
  }

  _SelectionTreeKey _selectionKey(LibraryFacade library) => (
    _queryRevision,
    _filters,
    library.structureRevision,
    library.detailCacheService.revision,
    _filters.hasSubtitle == null ? 0 : _subtitleRevision,
  );

  List<LibraryNode> get _currentSearchTree {
    final selection = _searchSelection;
    if (_submittedQuery == null ||
        selection == null ||
        selection.$1 != _selectionKey(ref.read(libraryFacadeProvider))) {
      return const [];
    }
    return selection.$2;
  }

  void _acceptSearchTree(_SelectionTreeKey key, List<LibraryNode> tree) {
    if (_submittedQuery == null ||
        key != _selectionKey(ref.read(libraryFacadeProvider))) {
      return;
    }
    setState(() {
      _searchSelection = (key, tree);
      if (_selectedLibraryPaths.isNotEmpty) {
        _selectedLibraryPaths = {
          for (final node in tree)
            if (isSelectableLibraryNode(node) &&
                _selectedLibraryPaths.contains(
                  selectionKeyForLibraryNode(node),
                ))
              selectionKeyForLibraryNode(node),
        };
        if (_selectedLibraryPaths.isEmpty) _isSelectionMode = false;
      }
    });
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted ||
        !_isSelectionMode ||
        ModalRoute.of(context)?.isCurrent == false ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _exitSelectionMode();
    return true;
  }

  void _onChanged(String value) {
    final wasEnabled = _canSubmitDraft;
    final parsed = parseSearchElements(value);
    _parsedDraftElements = parsed;
    _canonicalDraftQuery = parsed == null ? '' : formatSearchElements(parsed);
    final enabled = _canSubmitElements(parsed, _filters);
    _draftQuery.value = value;
    _syncSuggestionSelection();
    if (_submittedQuery == null && !_isSelectionMode && enabled == wasEnabled) {
      return;
    }
    setState(() {
      _submittedQuery = null;
      _parsedSubmittedElements = null;
      _queryRevision++;
      _searchSelection = null;
      _clearSelection();
    });
  }

  void _setDraft(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onChanged(text);
  }

  void _toggleTerm(String element) {
    final elements = _parsedDraftElements;
    if (elements == null) return;
    _setDraft(toggleSearchElement(elements, element, matchAll: _matchAll));
  }

  void _removeElement(String query) {
    if (query.isEmpty && _filters == emptySearchFilters) {
      _setDraft('');
    } else {
      _onSubmitted(query, recordHistory: false);
    }
  }

  void _onSubmitted(String value, {bool recordHistory = true}) {
    final parsed = value == _draftQuery.value
        ? _parsedDraftElements
        : parseSearchElements(value);
    if (!_canSubmitElements(parsed, _filters)) return;
    final query = parsed == null ? '' : formatSearchElements(parsed);
    _parsedDraftElements = parsed;
    _canonicalDraftQuery = query;
    _draftQuery.value = query;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _syncSuggestionSelection(allowDuringComposing: true);
    setState(() {
      _submittedQuery = query;
      _parsedSubmittedElements = query.isEmpty ? null : parsed;
      _queryRevision++;
      _searchSelection = null;
      _clearSelection();
    });
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (!recordHistory || query.isEmpty) return;
    unawaited(
      saveSettingsWithFeedback(
        context,
        () => ref
            .read(settingsRepositoryProvider)
            .recordSearchQuery(query, online: false),
      ),
    );
  }

  void _closeOrClear() {
    if (_submittedQuery == null && _controller.text.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _controller.clear();
    _onChanged('');
  }

  void _clearSelection() {
    _isSelectionMode = false;
    _selectedLibraryPaths = const {};
  }

  void _enterSelectionMode(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths = {selectionKeyForLibraryNode(node)};
    });
  }

  void _exitSelectionMode() {
    setState(_clearSelection);
  }

  void _toggleLibrarySelection(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      final paths = Set<String>.of(_selectedLibraryPaths);
      final key = selectionKeyForLibraryNode(node);
      if (!paths.remove(key)) paths.add(key);
      _selectedLibraryPaths = paths;
      if (paths.isEmpty) _isSelectionMode = false;
    });
  }

  void _toggleSelectAllSearchResults() {
    final selectableKeys = <String>[
      for (final node in _currentSearchTree)
        if (isSelectableLibraryNode(node)) selectionKeyForLibraryNode(node),
    ];
    if (selectableKeys.isEmpty) return;
    final allSelected = selectableKeys.every(_selectedLibraryPaths.contains);
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _selectedLibraryPaths = allSelected
          ? const <String>{}
          : selectableKeys.toSet();
    });
  }

  void _clearFilters() {
    setState(() {
      _filters = emptySearchFilters;
      _queryRevision++;
      _clearSelection();
      if (_submittedQuery == '') {
        _submittedQuery = null;
        _parsedSubmittedElements = null;
        _searchSelection = null;
      }
    });
  }

  void _editSearch() {
    setState(() {
      _submittedQuery = null;
      _parsedSubmittedElements = null;
      _searchSelection = null;
      _clearSelection();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  List<LibraryBatchSelection> _currentSelections() =>
      selectedLibraryNodeSelections(_currentSearchTree, _selectedLibraryPaths);

  Future<void> _addCurrentSelectionsToPlaylist() async {
    final selections = _currentSelections();
    if (selections.isEmpty) return;
    await addLibraryBatchSelectionsToPlaylist(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  Future<void> _completeCurrentSelectionsMetadata() async {
    final selections = _currentSelections();
    if (selections.isEmpty) return;
    await completeLibraryBatchSelectionsMetadata(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  Future<void> _toggleCurrentSelectionsPinned() async {
    final selections = _currentSelections();
    if (selections.isEmpty) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final paths = selections
        .map((selection) => selection.path)
        .toList(growable: false);
    _exitSelectionMode();
    await saveSettingsWithFeedback(
      context,
      () =>
          ref.read(settingsRepositoryProvider).toggleLibraryPathsPinned(paths),
    );
  }

  Future<void> _removeCurrentSelections() async {
    final selections = _currentSelections();
    if (selections.isEmpty) return;
    await removeLibraryBatchSelections(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    _focusNode.dispose();
    _draftQuery.dispose();
    _suggestionSelection.dispose();
    _resultsScrollController.dispose();
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _suggestionsScrollController.dispose();
    _observedSubtitleService?.removeListener(_handleSubtitlesChanged);
    _observedSubtitleService = null;
    _searchIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    _observeSubtitleService(ref.watch(playbackSubtitleServiceProvider));
    ref.watch(libraryListUiProvider.select((state) => state.structureRevision));
    ref.watch(libraryDetailRevisionProvider);
    final structureRevision = libraryFacade.structureRevision;
    final detailRevision = libraryFacade.detailCacheService.revision;
    final cached = libraryFacade.categorySnapshot;
    final topInset = _isSelectionMode
        ? AppPageHeaderMetrics.contentTopInset(
            context,
            additionalHeight: 6 + AppPageHeaderMetrics.buttonSize,
          )
        : AppSearchPageScaffold.controlsTopInset(context, hasCategories: false);
    final query = _submittedQuery;
    final selectionKey = _selectionKey(libraryFacade);
    Widget scaffold = AppSearchPageScaffold<AudioLibraryCategoryType>(
      controller: _controller,
      focusNode: _focusNode,
      requestInitialFocus: widget.initialQuery.isEmpty,
      hintText: i18n.tr('search_audio_placeholder'),
      onChanged: _onChanged,
      onSubmitted: _onSubmitted,
      committedElements: _parsedSubmittedElements,
      onRemoveElement: _removeElement,
      translate: i18n.tr,
      onCloseOrClear: _closeOrClear,
      showConfirmButton: query == null,
      onConfirm: _canSubmitDraft ? () => _onSubmitted(_controller.text) : null,
      confirmLabel: i18n.tr('confirm'),
      controlsOverlay: _isSelectionMode ? _buildSelectionHeader(i18n) : null,
      body: PageHeaderInset(
        topInset: topInset,
        child: AppDeferredContent(
          // A cold snapshot loads metadata for the entire library. Keep that
          // query out of entrance frames while retaining warm suggestions.
          prepared:
              cached?.structureRevision == structureRevision &&
              cached?.detailRevision == detailRevision,
          placeholder: const SizedBox.shrink(),
          builder: (_) => _buildSuggestions(
            libraryFacade,
            structureRevision,
            detailRevision,
            topInset,
          ),
        ),
      ),
      resultsBody: query == null
          ? null
          : PageHeaderInset(
              topInset: topInset,
              child: HeroMode(
                key: const ValueKey('library_search_hero_mode'),
                enabled: false,
                child: LibrarySearchAllResults(
                  key: const ValueKey('library_search_confirmed'),
                  query: query,
                  filters: _filters,
                  queryRevision: _queryRevision,
                  structureRevision: structureRevision,
                  detailRevision: detailRevision,
                  subtitleRevision: _subtitleRevision,
                  scrollController: _resultsScrollController,
                  topPadding: topInset,
                  isSelectionMode: _isSelectionMode,
                  selectedPaths: _selectedLibraryPaths,
                  onEnterSelectionMode: _enterSelectionMode,
                  onToggleSelection: _toggleLibrarySelection,
                  onTreeChanged: (tree) =>
                      _acceptSearchTree(selectionKey, tree),
                  searchIndex: _searchIndex,
                  onClearFilters: _clearFilters,
                  onEditSearch: _editSearch,
                ),
              ),
            ),
    );
    return PopScope<void>(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelectionMode) {
          _exitSelectionMode();
        }
      },
      child: scaffold,
    );
  }

  Widget _buildSuggestions(
    LibraryFacade libraryFacade,
    int structureRevision,
    int detailRevision,
    double topInset,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    Future<AudioLibraryCategorySnapshot> loadSnapshot() =>
        libraryFacade.audioLibraryCategorySnapshot(
          isActive: () =>
              mounted &&
              _categorySnapshotStructureRevision == structureRevision &&
              _categorySnapshotDetailRevision == detailRevision,
        );
    if (_categorySnapshotFuture == null ||
        _categorySnapshotStructureRevision != structureRevision ||
        _categorySnapshotDetailRevision != detailRevision) {
      _categorySnapshotStructureRevision = structureRevision;
      _categorySnapshotDetailRevision = detailRevision;
      _categorySnapshotFuture = loadSnapshot();
    }
    final cached = libraryFacade.categorySnapshot;
    return FutureBuilder<AudioLibraryCategorySnapshot>(
      future: _categorySnapshotFuture,
      initialData:
          cached?.structureRevision == structureRevision &&
              cached?.detailRevision == detailRevision
          ? cached
          : null,
      builder: (context, state) => Consumer(
        builder: (context, ref, _) {
          final history = ref.watch(
            settingsStateProvider.select(
              (state) => state.value?.librarySearchHistory ?? const <String>[],
            ),
          );
          return CustomScrollView(
            key: const ValueKey('library_search_suggestions'),
            controller: _suggestionsScrollController,
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                  top: topInset,
                  bottom: AppSearchPageScaffold.contentBottomInset(context),
                ),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: ValueListenableBuilder<String>(
                        valueListenable: _draftQuery,
                        builder: (context, draft, _) => AppSearchElementTabs(
                          draft: draft,
                          matchAll: _matchAll,
                          onSelected: (value) {
                            setState(() => _matchAll = value);
                            _syncSuggestionSelection(
                              allowDuringComposing: true,
                            );
                          },
                          translate: i18n.tr,
                          filters: _filters,
                          onFiltersChanged: (value) =>
                              setState(() => _filters = value),
                        ),
                      ),
                    ),
                    ValueListenableBuilder<_LibrarySuggestionSelection>(
                      valueListenable: _suggestionSelection,
                      builder: (context, selection, _) {
                        final selectedLowerSet = selection.selectedLowerTerms;
                        final canonicalDraft = selection.canonicalDraft;
                        bool isSelected(String element) =>
                            selectedLowerSet.isNotEmpty &&
                            selectedLowerSet.contains(element.toLowerCase());

                        AppSearchSuggestionSection section(
                          String key,
                          String title,
                          List<String> items,
                          String emptyText, {
                          bool metadata = false,
                          bool isHistory = false,
                          VoidCallback? onClear,
                        }) => AppSearchSuggestionSection(
                          key: ValueKey(key),
                          title: title,
                          items: items,
                          isSelected: isHistory
                              ? (item) => item == canonicalDraft
                              : isSelected,
                          onToggle: isHistory ? _onSubmitted : _toggleTerm,
                          buildItemMenu: isHistory
                              ? (item) => buildSearchHistoryMenu(
                                  context,
                                  item,
                                  online: false,
                                )
                              : null,
                          emptyText: emptyText,
                          expandLabel: i18n.tr('expand'),
                          collapseLabel: i18n.tr('collapse'),
                          onClear: onClear,
                          clearLabel: i18n.tr('clear'),
                          isLoading:
                              metadata &&
                              state.connectionState ==
                                  ConnectionState.waiting &&
                              state.data == null,
                          errorText: metadata && state.hasError
                              ? i18n.tr('operation_failed_retry')
                              : null,
                          retryLabel: i18n.tr('retry'),
                          onRetry: metadata && state.hasError
                              ? () => setState(() {
                                  _categorySnapshotFuture = loadSnapshot();
                                })
                              : null,
                        );

                        return SliverMainAxisGroup(
                          slivers: [
                            section(
                              'library_search_history',
                              i18n.tr('search_history'),
                              history,
                              i18n.tr('search_history_empty'),
                              isHistory: true,
                              onClear: () => unawaited(
                                clearSearchHistoryWithFeedback(
                                  context,
                                  online: false,
                                ),
                              ),
                            ),
                            section(
                              'library_search_voices',
                              i18n.tr('library_category_voice_actors'),
                              state.data?.voiceActorTerms ?? const [],
                              i18n.tr('library_category_no_voice_actors'),
                              metadata: true,
                            ),
                            section(
                              'library_search_tags',
                              i18n.tr('library_category_tags'),
                              state.data?.tagTerms ?? const [],
                              i18n.tr('library_category_no_tags'),
                              metadata: true,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSelectionHeader(AppLanguageProvider i18n) {
    final coreReady = ref.watch(coreRuntimeReadyProvider);
    final pinnedLibraryPaths = ref
        .watch(
          settingsStateProvider.select(
            (state) => state.value?.pinnedLibraryPaths ?? const <String>[],
          ),
        )
        .toSet();
    final selectionTree = _currentSearchTree;
    final selectableNodes = selectionTree
        .where(isSelectableLibraryNode)
        .toList(growable: false);
    final selectedSelections = selectedLibraryNodeSelections(
      selectionTree,
      _selectedLibraryPaths,
    );
    final allSelected =
        selectableNodes.isNotEmpty &&
        selectedSelections.length >= selectableNodes.length;
    final isAllPinned =
        _selectedLibraryPaths.isNotEmpty &&
        _selectedLibraryPaths.every(
          (path) => pinnedLibraryPaths.contains(PathMatcher.normalize(path)),
        );
    return LibraryBatchSelectionHeader(
      keyPrefix: 'library_search',
      i18n: i18n,
      selectedCount: selectedSelections.length,
      allSelected: allSelected,
      onToggleSelectAll: selectableNodes.isEmpty
          ? null
          : _toggleSelectAllSearchResults,
      onEditInfo: selectedSelections.length == 1
          ? () {
              final target = selectedSelections.single.target;
              _exitSelectionMode();
              unawaited(showAudioDetailEditor(context, ref, target));
            }
          : null,
      isPinned: isAllPinned,
      onAddToPlaylist: !coreReady || selectedSelections.isEmpty
          ? null
          : () => unawaited(_addCurrentSelectionsToPlaylist()),
      onCompleteMetadata: selectedSelections.isEmpty
          ? null
          : () => unawaited(_completeCurrentSelectionsMetadata()),
      onTogglePin: selectedSelections.isEmpty
          ? null
          : () => unawaited(_toggleCurrentSelectionsPinned()),
      onRemove: selectedSelections.isEmpty
          ? null
          : () => unawaited(_removeCurrentSelections()),
      onExit: _exitSelectionMode,
    );
  }
}

@immutable
class _LibrarySuggestionSelection {
  const _LibrarySuggestionSelection({
    this.canonicalDraft = '',
    this.selectedLowerTerms = const <String>{},
  });

  final String canonicalDraft;
  final Set<String> selectedLowerTerms;

  @override
  bool operator ==(Object other) =>
      other is _LibrarySuggestionSelection &&
      other.canonicalDraft == canonicalDraft &&
      setEquals(other.selectedLowerTerms, selectedLowerTerms);

  @override
  int get hashCode =>
      Object.hash(canonicalDraft, Object.hashAllUnordered(selectedLowerTerms));
}
