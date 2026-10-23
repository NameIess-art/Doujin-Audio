import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../application/library_facade.dart';
import '../application/library_snapshot_cache_service.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../app/theme/app_styles.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_empty_scan.dart';
import 'library_search_all_results.dart';
import 'library_tab_category_widgets.dart';

final _categoryTermSplitRegex = RegExp(r'[\s,，;；|]+');

class LibrarySearchPage extends ConsumerStatefulWidget {
  const LibrarySearchPage({super.key});

  @override
  ConsumerState<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _CategoryFilterCache {
  AudioLibraryCategorySnapshot? snapshot;
  String? filterKey;
  LibraryCategoryFilterResult? result;
  AudioLibraryCategorySnapshot? pendingSnapshot;
  String? pendingKey;
  Object? error;
  int requestId = 0;
  final revision = ValueNotifier<int>(0);
}

class _LibrarySearchPageState extends ConsumerState<LibrarySearchPage> {
  static const _categories = <AudioLibraryCategoryType>[
    AudioLibraryCategoryType.all,
    AudioLibraryCategoryType.tags,
    AudioLibraryCategoryType.voiceActors,
    AudioLibraryCategoryType.circles,
  ];

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _allScrollController = ScrollController(
    keepScrollOffset: false,
  );
  final ScrollController _categoryScrollController = ScrollController(
    keepScrollOffset: false,
  );
  // Retained pages keep these references in their content revision. Replace
  // collections on selection changes so hidden pages receive the latest inputs.
  Map<AudioLibraryCategoryType, Set<String>> _selectedCategoryTerms = const {};
  Set<String> _selectedLibraryPaths = const {};
  final Map<AudioLibraryCategoryType, String> _termSearchQueries = {};

  final ValueNotifier<int> _activeCategoryIndex = ValueNotifier<int>(0);
  final ValueNotifier<int> _activeBodyIndex = ValueNotifier<int>(0);
  AudioLibraryCategoryType _lastTermCategory = AudioLibraryCategoryType.tags;
  final Set<AudioLibraryCategoryType> _visitedTermCategories = {};

  Timer? _debounceTimer;
  bool _isSelectionMode = false;
  String _query = '';
  int _queryRevision = 0;

  List<LibraryNode> _searchSelectionTree = const [];

  final Map<AudioLibraryCategoryType, _CategoryFilterCache>
  _categoryFilterCaches = {};
  Future<AudioLibraryCategorySnapshot>? _categorySnapshotFuture;
  int? _categorySnapshotStructureRevision;
  int? _categorySnapshotDetailRevision;

  AudioLibraryCategoryType get _categoryType =>
      _categories[_activeCategoryIndex.value];

  ScrollController get _activeScrollController =>
      _categoryType == AudioLibraryCategoryType.all
      ? _allScrollController
      : _categoryScrollController;

  void _resetScroll() {
    final controller = _activeScrollController;
    if (controller.hasClients) {
      controller.jumpTo(0);
    }
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
      _resetScroll();
      setState(() {
        _query = query;
        _queryRevision++;
        _searchSelectionTree = const [];
        _clearSelection();
      });
    });
  }

  void _onSubmitted(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (_query != query) {
      _resetScroll();
      setState(() {
        _query = query;
        _queryRevision++;
        _searchSelectionTree = const [];
        _clearSelection();
      });
    }
    FocusManager.instance.primaryFocus?.unfocus();
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
      _queryRevision++;
      _searchSelectionTree = const [];
      _clearSelection();
    });
  }

  void _selectCategory(AudioLibraryCategoryType category) {
    if (_categoryType == category) return;
    final outgoingKey = _categoryCacheKey(_categoryType);
    final outgoing = _categoryFilterCaches[outgoingKey];
    if (outgoing != null &&
        (category == AudioLibraryCategoryType.all ||
            outgoingKey != _categoryCacheKey(category))) {
      outgoing.requestId++;
      outgoing.pendingKey = null;
      UiInteractionCoordinator.instance.cancelCommit(
        _categoryCommitKey(outgoingKey),
      );
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final controller = _activeScrollController;
    if (controller.hasClients) {
      controller.jumpTo(controller.offset);
    }
    if (_isSelectionMode) setState(_clearSelection);
    final targetIndex = _categories.indexOf(category);
    if (targetIndex >= 0) {
      if (category != AudioLibraryCategoryType.all) {
        _lastTermCategory = category;
        _visitedTermCategories.add(category);
      }
      _activeCategoryIndex.value = targetIndex;
      _activeBodyIndex.value = category == AudioLibraryCategoryType.all ? 0 : 1;
    }
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

  void _enterCategorySelectionMode(AudioLibraryCategoryEntry entry) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths = {PathMatcher.normalize(entry.path)};
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(_clearSelection);
  }

  void _toggleLibrarySelection(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    _toggleSelectionKey(selectionKeyForLibraryNode(node));
  }

  void _toggleCategorySelection(AudioLibraryCategoryEntry entry) {
    _toggleSelectionKey(PathMatcher.normalize(entry.path));
  }

  void _toggleSelectionKey(String key) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      final paths = Set<String>.of(_selectedLibraryPaths);
      if (!paths.remove(key)) paths.add(key);
      _selectedLibraryPaths = paths;
      if (paths.isEmpty) _isSelectionMode = false;
    });
  }

  List<LibraryBatchSelection> _selectedCategorySelections(
    AudioLibraryCategorySnapshot? snapshot,
  ) => (snapshot?.entries ?? const <AudioLibraryCategoryEntry>[])
      .where(
        (entry) =>
            _selectedLibraryPaths.contains(PathMatcher.normalize(entry.path)),
      )
      .map(LibraryBatchSelection.fromCategoryEntry)
      .toList(growable: false);

  Future<List<LibraryBatchSelection>> _currentSelections() async {
    if (_categoryType == AudioLibraryCategoryType.all) {
      return selectedLibraryNodeSelections(
        _searchSelectionTree,
        _selectedLibraryPaths,
      );
    }
    final snapshot = await ref
        .read(libraryFacadeProvider)
        .audioLibraryCategorySnapshot();
    return _selectedCategorySelections(snapshot);
  }

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
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _activeCategoryIndex.dispose();
    _activeBodyIndex.dispose();
    _allScrollController.dispose();
    _categoryScrollController.dispose();
    for (final cache in _categoryFilterCaches.entries) {
      UiInteractionCoordinator.instance.cancelCommit(
        _categoryCommitKey(cache.key),
      );
      cache.value.revision.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
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
    final topInset = _isSelectionMode
        ? AppPageHeaderMetrics.expandedToolbarHeight +
              MediaQuery.paddingOf(context).top +
              AppPageHeaderMetrics.bottomSpacing
        : AppSearchPageScaffold.controlsTopInset(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom + 16;

    final body = Consumer(
      builder: (context, ref, _) {
        final libraryFacade = ref.read(libraryFacadeProvider);
        ref.watch(
          libraryListUiProvider.select((state) => state.structureRevision),
        );
        ref.watch(libraryDetailRevisionProvider);
        final structureRevision = libraryFacade.structureRevision;
        final detailRevision = libraryFacade.detailCacheService.revision;
        final pinnedLibraryPaths = ref.watch(
          settingsStateProvider.select(
            (s) => s.value?.pinnedLibraryPaths ?? const <String>[],
          ),
        );
        final pinnedPaths = pinnedLibraryPaths.toSet();
        return AppFadeThroughIndexedStack.lazy(
          key: const ValueKey<String>('library_search_category_stack'),
          indexListenable: _activeBodyIndex,
          contentRevision: (
            libraryFacade,
            structureRevision,
            detailRevision,
            i18n.language,
            _query,
            _queryRevision,
            _isSelectionMode,
            _selectedLibraryPaths,
            _selectedCategoryTerms,
            _termSearchQueries[AudioLibraryCategoryType.tags],
            _termSearchQueries[AudioLibraryCategoryType.voiceActors],
            _termSearchQueries[AudioLibraryCategoryType.circles],
            pinnedLibraryPaths,
            topInset,
            bottomInset,
          ),
          itemCount: 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return LibrarySearchAllResults(
                isActive: () => _categoryType == AudioLibraryCategoryType.all,
                activityListenable: _activeCategoryIndex,
                query: _query,
                queryRevision: _queryRevision,
                structureRevision: structureRevision,
                detailRevision: detailRevision,
                scrollController: _allScrollController,
                topPadding: topInset,
                isSelectionMode: _isSelectionMode,
                selectedPaths: _selectedLibraryPaths,
                onEnterSelectionMode: _enterSelectionMode,
                onToggleSelection: _toggleLibrarySelection,
                onTreeChanged: (tree) => _searchSelectionTree = tree,
              );
            }
            return ValueListenableBuilder<int>(
              valueListenable: _activeCategoryIndex,
              builder: (context, _, _) => _buildCategoryBody(
                categoryType: _lastTermCategory,
                libraryFacade: libraryFacade,
                i18n: i18n,
                topPadding: topInset,
                bottomPadding: bottomInset,
                cacheExtent: 120,
                structureRevision: structureRevision,
                detailRevision: detailRevision,
                pinnedPaths: pinnedPaths,
              ),
            );
          },
        );
      },
    );

    return ValueListenableBuilder<int>(
      valueListenable: _activeCategoryIndex,
      child: HeroMode(
        key: const ValueKey<String>('library_search_hero_mode'),
        enabled: false,
        child: body,
      ),
      builder: (context, index, body) =>
          AppSearchPageScaffold<AudioLibraryCategoryType>(
            controller: _controller,
            focusNode: _focusNode,
            hintText: i18n.tr('search_audio_placeholder'),
            categories: categories,
            selectedCategory: _categories[index],
            onCategorySelected: _selectCategory,
            onChanged: _onChanged,
            onSubmitted: _onSubmitted,
            onCloseOrClear: _closeOrClear,
            body: body!,
            controlsOverlay: _isSelectionMode
                ? Consumer(
                    builder: (context, ref, _) {
                      final pinnedLibraryPaths = ref
                          .watch(
                            settingsStateProvider.select(
                              (s) =>
                                  s.value?.pinnedLibraryPaths ??
                                  const <String>[],
                            ),
                          )
                          .toSet();
                      final isAllPinned =
                          _selectedLibraryPaths.isNotEmpty &&
                          _selectedLibraryPaths.every(
                            (p) => pinnedLibraryPaths.contains(
                              PathMatcher.normalize(p),
                            ),
                          );
                      return LibraryBatchSelectionHeader(
                        keyPrefix: 'library_search',
                        i18n: i18n,
                        selectedCount: _selectedLibraryPaths.length,
                        isPinned: isAllPinned,
                        onAddToPlaylist: _selectedLibraryPaths.isEmpty
                            ? null
                            : () =>
                                  unawaited(_addCurrentSelectionsToPlaylist()),
                        onCompleteMetadata: _selectedLibraryPaths.isEmpty
                            ? null
                            : () => unawaited(
                                _completeCurrentSelectionsMetadata(),
                              ),
                        onTogglePin: _selectedLibraryPaths.isEmpty
                            ? null
                            : () => unawaited(_toggleCurrentSelectionsPinned()),
                        onRemove: _selectedLibraryPaths.isEmpty
                            ? null
                            : () => unawaited(_removeCurrentSelections()),
                        onExit: _exitSelectionMode,
                      );
                    },
                  )
                : null,
          ),
    );
  }

  Set<String> _selectedTermsForCategory(AudioLibraryCategoryType category) {
    return _selectedCategoryTerms[category] ?? const <String>{};
  }

  List<String> _termSearchKeywordsForCategory(
    AudioLibraryCategoryType category,
  ) {
    final query = _termSearchQueries[category] ?? '';
    return query
        .toLowerCase()
        .split(_categoryTermSplitRegex)
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  IconData _categoryIcon(AudioLibraryCategoryType category) {
    return switch (category) {
      AudioLibraryCategoryType.tags => Icons.sell_rounded,
      AudioLibraryCategoryType.voiceActors => Icons.record_voice_over_rounded,
      AudioLibraryCategoryType.circles => Icons.groups_rounded,
      AudioLibraryCategoryType.all => Icons.confirmation_number_rounded,
    };
  }

  String _entrySecondaryText(
    AppLanguageProvider i18n,
    AudioLibraryCategoryEntry entry,
    AudioLibraryCategoryType category,
  ) {
    final values = switch (category) {
      AudioLibraryCategoryType.tags => entry.tagTerms,
      AudioLibraryCategoryType.voiceActors => entry.voiceActorTerms,
      AudioLibraryCategoryType.circles => entry.circleTerms,
      AudioLibraryCategoryType.all => [
        if (entry.detail.rjCode.trim().isNotEmpty)
          entry.detail.rjCode.trim()
        else
          i18n.tr('audio_detail_empty'),
      ],
    };
    return values.isEmpty ? i18n.tr('audio_detail_empty') : values.join(', ');
  }

  String _noTermsText(
    AppLanguageProvider i18n,
    AudioLibraryCategoryType category,
  ) {
    return switch (category) {
      AudioLibraryCategoryType.tags => i18n.tr('library_category_no_tags'),
      AudioLibraryCategoryType.voiceActors => i18n.tr(
        'library_category_no_voice_actors',
      ),
      AudioLibraryCategoryType.circles => i18n.tr(
        'library_category_no_circles',
      ),
      AudioLibraryCategoryType.all => '',
    };
  }

  String _categoryCommitKey(AudioLibraryCategoryType category) =>
      'library_category_search_${identityHashCode(this)}_${category.name}';

  AudioLibraryCategoryType _categoryCacheKey(
    AudioLibraryCategoryType category,
  ) =>
      // Without element filters, categories have identical rows and can share
      // both completed results and requests that are still running.
      _selectedTermsForCategory(category).isEmpty &&
          (_termSearchQueries[category]?.trim().isEmpty ?? true)
      ? AudioLibraryCategoryType.all
      : category;

  _CategoryFilterCache _cacheForCategory(AudioLibraryCategoryType category) =>
      _categoryFilterCaches.putIfAbsent(
        _categoryCacheKey(category),
        () => _CategoryFilterCache()
          ..result =
              _categoryFilterCaches[AudioLibraryCategoryType.all]?.result,
      );

  List<String> _snapshotTerms(
    AudioLibraryCategorySnapshot? snapshot,
    AudioLibraryCategoryType category,
  ) => switch (category) {
    AudioLibraryCategoryType.tags => snapshot?.tagTerms ?? const [],
    AudioLibraryCategoryType.voiceActors =>
      snapshot?.voiceActorTerms ?? const [],
    AudioLibraryCategoryType.circles => snapshot?.circleTerms ?? const [],
    AudioLibraryCategoryType.all => const [],
  };

  void _ensureCategoryEntries(
    LibraryFacade libraryFacade,
    AudioLibraryCategorySnapshot snapshot,
    AudioLibraryCategoryType category, {
    Set<String> pinnedPaths = const <String>{},
  }) {
    final selectedTerms = _selectedTermsForCategory(category);
    final queryTerms = extractSearchTerms(
      _query,
    ).map((term) => term.toLowerCase()).toList(growable: false);
    final termKeywords = _termSearchKeywordsForCategory(category);
    final normalizedSelectedTerms =
        selectedTerms.map((term) => term.toLowerCase()).toList(growable: false)
          ..sort();
    final filterKey = <String>[
      queryTerms.join('\n'),
      termKeywords.join('\n'),
      normalizedSelectedTerms.join('\n'),
      pinnedPaths.join('\n'),
    ].join('|');
    final cacheKey = _categoryCacheKey(category);
    final cache = _cacheForCategory(category);
    if (identical(snapshot, cache.snapshot) && filterKey == cache.filterKey) {
      if (cache.pendingKey != null) {
        cache.requestId++;
        cache.pendingKey = null;
        cache.error = null;
        UiInteractionCoordinator.instance.cancelCommit(
          _categoryCommitKey(cacheKey),
        );
      }
      return;
    }
    if (identical(snapshot, cache.pendingSnapshot) &&
        filterKey == cache.pendingKey) {
      return;
    }
    cache.pendingSnapshot = snapshot;
    cache.pendingKey = filterKey;
    cache.error = null;
    final requestId = ++cache.requestId;
    bool isCurrent() =>
        mounted &&
        _categoryType != AudioLibraryCategoryType.all &&
        _categoryCacheKey(_categoryType) == cacheKey &&
        cache.requestId == requestId;
    void commit(VoidCallback update) {
      if (!isCurrent()) return;
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _categoryCommitKey(cacheKey),
        priority: 5,
        commit: () {
          if (!isCurrent()) return;
          update();
          cache.revision.value++;
        },
      );
    }

    unawaited(
      libraryFacade.snapshotCacheService
          .filterCategoryEntries((
            snapshot: snapshot,
            category: category,
            queryTerms: queryTerms,
            termKeywords: termKeywords,
            selectedTerms: selectedTerms,
            pinnedPaths: pinnedPaths,
          ))
          .then<void>(
            (result) {
              commit(() {
                cache.snapshot = snapshot;
                cache.filterKey = filterKey;
                cache.result = result;
                cache.pendingKey = null;
              });
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!isCurrent()) return;
              AppLogService.error(
                'library_category_search_failed',
                error: error,
                stackTrace: stackTrace,
              );
              commit(() => cache.error = error);
            },
          ),
    );
  }

  String _termSearchHintText(
    AppLanguageProvider i18n,
    AudioLibraryCategoryType category,
  ) {
    final searchPrefix = i18n.tr('search');
    return switch (category) {
      AudioLibraryCategoryType.tags =>
        '$searchPrefix${i18n.tr('library_category_tags')}...',
      AudioLibraryCategoryType.voiceActors =>
        '$searchPrefix${i18n.tr('library_category_voice_actors')}...',
      AudioLibraryCategoryType.circles =>
        '$searchPrefix${i18n.tr('library_category_circles')}...',
      AudioLibraryCategoryType.all => '$searchPrefix...',
    };
  }

  Widget _buildTermBox(
    AudioLibraryCategoryType categoryType,
    AppLanguageProvider i18n,
    List<String> terms,
  ) {
    return LibraryCategoryTermBox(
      key: ValueKey('library_category_term_box_${categoryType.name}'),
      categoryType: categoryType,
      collapseOnMount: true,
      terms: terms,
      selectedTerms: _selectedTermsForCategory(categoryType),
      emptyText: _noTermsText(i18n, categoryType),
      clearLabel: i18n.tr('clear'),
      collapseLabel: i18n.tr('collapse'),
      expandLabel: i18n.tr('expand'),
      searchHintText: _termSearchHintText(i18n, categoryType),
      searchQuery: _termSearchQueries[categoryType] ?? '',
      onSearchQueryChanged: (val) {
        setState(() {
          if (val.isEmpty) {
            _termSearchQueries.remove(categoryType);
          } else {
            _termSearchQueries[categoryType] = val;
          }
        });
      },
      onToggle: (term) {
        setState(() {
          final terms = Set<String>.of(_selectedTermsForCategory(categoryType));
          if (!terms.remove(term)) terms.add(term);
          _selectedCategoryTerms = {
            ..._selectedCategoryTerms,
            categoryType: terms,
          };
        });
      },
      onClear: () {
        if (_selectedTermsForCategory(categoryType).isEmpty) {
          return;
        }
        setState(() {
          _selectedCategoryTerms = Map.of(_selectedCategoryTerms)
            ..remove(categoryType);
        });
      },
    );
  }

  Widget _buildCategoryBody({
    required AudioLibraryCategoryType categoryType,
    required LibraryFacade libraryFacade,
    required AppLanguageProvider i18n,
    required double topPadding,
    required double bottomPadding,
    required double cacheExtent,
    required int structureRevision,
    required int detailRevision,
    Set<String> pinnedPaths = const <String>{},
  }) {
    final cachedSnapshot = libraryFacade.categorySnapshot;
    if (_categorySnapshotFuture == null ||
        _categorySnapshotStructureRevision != structureRevision ||
        _categorySnapshotDetailRevision != detailRevision) {
      _categorySnapshotStructureRevision = structureRevision;
      _categorySnapshotDetailRevision = detailRevision;
      _categorySnapshotFuture = libraryFacade.audioLibraryCategorySnapshot();
    }
    final cache = _cacheForCategory(categoryType);
    return ValueListenableBuilder<int>(
      valueListenable: cache.revision,
      builder: (context, _, _) => FutureBuilder<AudioLibraryCategorySnapshot>(
        key: const ValueKey('category_future'),
        future: _categorySnapshotFuture,
        initialData:
            cachedSnapshot?.structureRevision == structureRevision &&
                cachedSnapshot?.detailRevision == detailRevision
            ? cachedSnapshot
            : null,
        builder: (context, snapshotState) {
          final snapshot = snapshotState.data;
          // FutureBuilder retains the last data while a new snapshot loads.
          // Keep that list mounted, but only filter the current revision.
          if (!snapshotState.hasError &&
              snapshot != null &&
              snapshot.structureRevision == structureRevision &&
              snapshot.detailRevision == detailRevision &&
              categoryType == _categoryType) {
            _ensureCategoryEntries(
              libraryFacade,
              snapshot,
              categoryType,
              pinnedPaths: pinnedPaths,
            );
          }
          final error = snapshotState.error ?? cache.error;
          final entries =
              cache.result?.entries ?? const <AudioLibraryCategoryEntry>[];
          final terms = _termSearchKeywordsForCategory(categoryType).isEmpty
              ? _snapshotTerms(snapshot, categoryType)
              : cache.result?.terms ?? const <String>[];
          Map<String, FolderNode>? foldersByPath;
          FolderNode? folderForEntry(AudioLibraryCategoryEntry entry) {
            if (!entry.isFolder) return null;
            foldersByPath ??= <String, FolderNode>{
              for (final folder
                  in libraryFacade.libraryCards.whereType<FolderNode>())
                PathMatcher.normalize(folder.path): folder,
            };
            return foldersByPath![PathMatcher.normalize(entry.path)];
          }

          final itemCount = entries.length + 2;
          final selectedTerms = _selectedTermsForCategory(categoryType);

          final highlightTerms = <String>{
            ...extractSearchTerms(_query),
            ...selectedTerms,
            ..._termSearchKeywordsForCategory(categoryType),
          }.where((t) => t.trim().isNotEmpty).toList(growable: false);

          Map<Key, int>? entryIndices;
          final list = SearchHighlightScope.withTerms(
            terms: highlightTerms,
            child: ListView.builder(
              key: const ValueKey('library_category_results'),
              controller: _categoryScrollController,
              padding: EdgeInsets.fromLTRB(
                LibraryLikeCardMetrics.listHorizontalPadding,
                topPadding,
                LibraryLikeCardMetrics.listHorizontalPadding,
                bottomPadding,
              ),
              cacheExtent: cacheExtent,
              clipBehavior: Clip.none,
              physics: const ClampingScrollPhysics(),
              itemCount: itemCount,
              findChildIndexCallback: (key) {
                if (key == const ValueKey('category_bottom')) {
                  return itemCount - 1;
                }
                if (key == const ValueKey('library_category_term_selector')) {
                  return 0;
                }
                entryIndices ??= {
                  for (var index = 0; index < entries.length; index++)
                    ValueKey('category_${entries[index].target.targetPath}'):
                        index + 1,
                };
                return entryIndices![key];
              },
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Stack(
                    key: const ValueKey('library_category_term_selector'),
                    children: [
                      for (final type in _categories.skip(1))
                        if (_visitedTermCategories.contains(type))
                          Offstage(
                            key: ValueKey(type),
                            offstage: type != categoryType,
                            child: TickerMode(
                              enabled: type == categoryType,
                              child: _buildTermBox(
                                type,
                                i18n,
                                type == categoryType
                                    ? terms
                                    : _snapshotTerms(snapshot, type),
                              ),
                            ),
                          ),
                    ],
                  );
                }

                final entryIndex = index - 1;
                if (entryIndex == entries.length) {
                  return AppDeferredFade(
                    key: const ValueKey('category_bottom'),
                    visible: entries.isEmpty,
                    child: SizedBox(
                      height: 220,
                      child: Center(
                        child: Text(
                          i18n.tr('library_category_no_matches'),
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ),
                  );
                }

                final entry = entries[entryIndex];
                return RepaintBoundary(
                  key: ValueKey('category_${entry.target.targetPath}'),
                  child: AudioLibraryCategoryEntryCard(
                    entry: entry,
                    folder: folderForEntry(entry),
                    secondaryIcon: _categoryIcon(categoryType),
                    secondaryText: _entrySecondaryText(
                      i18n,
                      entry,
                      categoryType,
                    ),
                    isSelectionMode: _isSelectionMode,
                    isSelected: _selectedLibraryPaths.contains(
                      PathMatcher.normalize(entry.path),
                    ),
                    onLongPress: () => _enterCategorySelectionMode(entry),
                    onToggleSelect: () => _toggleCategorySelection(entry),
                  ),
                );
              },
            ),
          );

          return PlaceholderContentTransition(
            showPlaceholder: error != null || cache.result == null,
            placeholder: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : kAppFadeDuration,
              switchInCurve: kAppFadeCurve,
              switchOutCurve: kAppFadeCurve,
              child: error != null
                  ? AppErrorState(
                      key: ValueKey(
                        'library_category_error_${categoryType.name}',
                      ),
                      title: i18n.tr('error'),
                      message: i18n.tr('operation_failed_retry'),
                      retryLabel: i18n.tr('retry'),
                      onRetry: () {
                        if (snapshotState.hasError) {
                          _categorySnapshotFuture = libraryFacade
                              .audioLibraryCategorySnapshot();
                        } else {
                          cache.pendingKey = null;
                          cache.error = null;
                        }
                        cache.revision.value++;
                      },
                    )
                  : LibraryLoadingSkeleton(
                      bottomInset: bottomPadding,
                      topInset: topPadding,
                    ),
            ),
            content: list,
          );
        },
      ),
    );
  }
}
