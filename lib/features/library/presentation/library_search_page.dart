import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/drag_only_scrollbar.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/library_facade.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import 'library_providers.dart';
import 'library_search_all_results.dart';
import 'library_tab_ui_helpers.dart';

class LibrarySearchPage extends ConsumerStatefulWidget {
  const LibrarySearchPage({super.key});

  @override
  ConsumerState<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends ConsumerState<LibrarySearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _draftQuery = ValueNotifier<String>('');
  final _resultsScrollController = ScrollController(keepScrollOffset: false);
  final _suggestionsScrollController = ScrollController(
    keepScrollOffset: false,
  );
  String? _submittedQuery;
  int _queryRevision = 0;
  bool _isSelectionMode = false;
  Set<String> _selectedLibraryPaths = const {};
  List<LibraryNode> _searchSelectionTree = const [];
  Future<AudioLibraryCategorySnapshot>? _categorySnapshotFuture;
  int? _categorySnapshotStructureRevision;
  int? _categorySnapshotDetailRevision;

  void _onChanged(String value) {
    final enabled = extractSearchTerms(value).isNotEmpty;
    final wasEnabled = extractSearchTerms(_draftQuery.value).isNotEmpty;
    _draftQuery.value = value;
    if (_submittedQuery == null && !_isSelectionMode && enabled == wasEnabled) {
      return;
    }
    setState(() {
      _submittedQuery = null;
      _queryRevision++;
      _searchSelectionTree = const [];
      _clearSelection();
    });
  }

  void _toggleTerm(String element) {
    final text = toggleSearchQueryTerms(_controller.text, element);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onChanged(text);
  }

  void _onSubmitted(String value) {
    final query = canonicalSearchQuery(value);
    if (query.isEmpty) return;
    _draftQuery.value = query;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _submittedQuery = query;
      _queryRevision++;
      _searchSelectionTree = const [];
      _clearSelection();
    });
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    FocusManager.instance.primaryFocus?.unfocus();
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
    if (_controller.text.isEmpty) {
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
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
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

  Future<List<LibraryBatchSelection>> _currentSelections() async =>
      selectedLibraryNodeSelections(
        _searchSelectionTree,
        _selectedLibraryPaths,
      );

  Future<void> _addCurrentSelectionsToPlaylist() async {
    final selections = await _currentSelections();
    if (!mounted) return;
    await addLibraryBatchSelectionsToPlaylist(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  Future<void> _completeCurrentSelectionsMetadata() async {
    final selections = await _currentSelections();
    if (!mounted) return;
    await completeLibraryBatchSelectionsMetadata(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  Future<void> _toggleCurrentSelectionsPinned() async {
    final selections = await _currentSelections();
    if (!mounted || selections.isEmpty) return;
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
    final selections = await _currentSelections();
    if (!mounted) return;
    await removeLibraryBatchSelections(
      context: context,
      ref: ref,
      selections: selections,
      exitSelectionMode: _exitSelectionMode,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _draftQuery.dispose();
    _resultsScrollController.dispose();
    _suggestionsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    ref.watch(libraryListUiProvider.select((state) => state.structureRevision));
    ref.watch(libraryDetailRevisionProvider);
    final structureRevision = libraryFacade.structureRevision;
    final detailRevision = libraryFacade.detailCacheService.revision;
    final topInset = _isSelectionMode
        ? AppPageHeaderMetrics.contentTopInset(
            context,
            additionalHeight: 6 + AppPageHeaderMetrics.buttonSize,
          )
        : AppSearchPageScaffold.controlsTopInset(context, hasCategories: false);
    final query = _submittedQuery;
    return AppSearchPageScaffold<AudioLibraryCategoryType>(
      controller: _controller,
      focusNode: _focusNode,
      hintText: i18n.tr('search_audio_placeholder'),
      onChanged: _onChanged,
      onSubmitted: _onSubmitted,
      onCloseOrClear: _closeOrClear,
      showConfirmButton: query == null,
      onConfirm: canonicalSearchQuery(_controller.text).isEmpty
          ? null
          : () => _onSubmitted(_controller.text),
      confirmLabel: i18n.tr('confirm'),
      controlsOverlay: _isSelectionMode ? _buildSelectionHeader(i18n) : null,
      body: PageHeaderInset(
        topInset: topInset,
        child: Builder(
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
                  queryRevision: _queryRevision,
                  structureRevision: structureRevision,
                  detailRevision: detailRevision,
                  scrollController: _resultsScrollController,
                  topPadding: topInset,
                  isSelectionMode: _isSelectionMode,
                  selectedPaths: _selectedLibraryPaths,
                  onEnterSelectionMode: _enterSelectionMode,
                  onToggleSelection: _toggleLibrarySelection,
                  onTreeChanged: (tree) => _searchSelectionTree = tree,
                ),
              ),
            ),
    );
  }

  Widget _buildSuggestions(
    LibraryFacade libraryFacade,
    int structureRevision,
    int detailRevision,
    double topInset,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (_categorySnapshotFuture == null ||
        _categorySnapshotStructureRevision != structureRevision ||
        _categorySnapshotDetailRevision != detailRevision) {
      _categorySnapshotStructureRevision = structureRevision;
      _categorySnapshotDetailRevision = detailRevision;
      _categorySnapshotFuture = libraryFacade.audioLibraryCategorySnapshot();
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
          return ValueListenableBuilder<String>(
            valueListenable: _draftQuery,
            builder: (context, draft, _) {
              final selected = normalizedSearchTerms(draft).toSet();
              bool isSelected(String element) {
                final terms = normalizedSearchTerms(element);
                return terms.isNotEmpty && terms.every(selected.contains);
              }

              AppSearchSuggestionSection section(
                String key,
                String title,
                List<String> items,
                String emptyText, {
                bool metadata = false,
                VoidCallback? onClear,
              }) => AppSearchSuggestionSection(
                key: ValueKey(key),
                title: title,
                items: items,
                isSelected: isSelected,
                onToggle: _toggleTerm,
                emptyText: emptyText,
                expandLabel: i18n.tr('expand'),
                collapseLabel: i18n.tr('collapse'),
                onClear: onClear,
                clearLabel: i18n.tr('clear'),
                isLoading:
                    metadata &&
                    state.connectionState == ConnectionState.waiting &&
                    state.data == null,
                errorText: metadata && state.hasError
                    ? i18n.tr('operation_failed_retry')
                    : null,
                retryLabel: i18n.tr('retry'),
                onRetry: metadata && state.hasError
                    ? () => setState(() {
                        _categorySnapshotFuture = libraryFacade
                            .audioLibraryCategorySnapshot();
                      })
                    : null,
              );
              return DragOnlyScrollbar(
                controller: _suggestionsScrollController,
                padding: EdgeInsets.only(top: topInset),
                child: CustomScrollView(
                  key: const ValueKey('library_search_suggestions'),
                  controller: _suggestionsScrollController,
                  physics: const ClampingScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.only(
                        top: topInset,
                        bottom: MediaQuery.paddingOf(context).bottom + 96,
                      ),
                      sliver: SliverMainAxisGroup(
                        slivers: [
                          section(
                            'library_search_history',
                            i18n.tr('search_history'),
                            history,
                            i18n.tr('search_history_empty'),
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
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSelectionHeader(AppLanguageProvider i18n) {
    final pinnedLibraryPaths = ref
        .watch(
          settingsStateProvider.select(
            (state) => state.value?.pinnedLibraryPaths ?? const <String>[],
          ),
        )
        .toSet();
    final isAllPinned =
        _selectedLibraryPaths.isNotEmpty &&
        _selectedLibraryPaths.every(
          (path) => pinnedLibraryPaths.contains(PathMatcher.normalize(path)),
        );
    return LibraryBatchSelectionHeader(
      keyPrefix: 'library_search',
      i18n: i18n,
      selectedCount: _selectedLibraryPaths.length,
      isPinned: isAllPinned,
      onAddToPlaylist: _selectedLibraryPaths.isEmpty
          ? null
          : () => unawaited(_addCurrentSelectionsToPlaylist()),
      onCompleteMetadata: _selectedLibraryPaths.isEmpty
          ? null
          : () => unawaited(_completeCurrentSelectionsMetadata()),
      onTogglePin: _selectedLibraryPaths.isEmpty
          ? null
          : () => unawaited(_toggleCurrentSelectionsPinned()),
      onRemove: _selectedLibraryPaths.isEmpty
          ? null
          : () => unawaited(_removeCurrentSelections()),
      onExit: _exitSelectionMode,
    );
  }
}
