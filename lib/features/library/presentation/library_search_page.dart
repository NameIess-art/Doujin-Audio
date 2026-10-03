import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/search_query_utils.dart';
import '../application/library_facade.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/visual_settings_providers.dart';
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
  List<AudioLibraryCategoryEntry> result = const [];
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
  final Map<AudioLibraryCategoryType, ScrollController> _scrollControllers = {
    for (final category in _categories)
      category: ScrollController(keepScrollOffset: false),
  };
  final Set<String> _selectedTagTerms = <String>{};
  final Set<String> _selectedVoiceActorTerms = <String>{};
  final Set<String> _selectedCircleTerms = <String>{};
  final Set<String> _selectedLibraryPaths = <String>{};
  final Map<AudioLibraryCategoryType, String> _termSearchQueries = {};

  late final ValueNotifier<int> _activeCategoryIndex;
  late final Set<AudioLibraryCategoryType> _visitedCategories;
  bool _animatingFromAll = false;

  Timer? _debounceTimer;
  AudioLibraryCategoryType _categoryType = AudioLibraryCategoryType.all;
  bool _hasSwitchedCategory = false;
  bool _isSelectionMode = false;
  String _query = '';
  int _queryRevision = 0;

  List<LibraryNode> _searchSelectionTree = const [];

  final Map<AudioLibraryCategoryType, _CategoryFilterCache>
      _categoryFilterCaches = {};
  Future<AudioLibraryCategorySnapshot>? _categorySnapshotFuture;
  int? _categorySnapshotStructureRevision;
  int? _categorySnapshotDetailRevision;

  String get _effectiveSearchQuery => _query;

  @override
  void initState() {
    super.initState();
    final initialIndex = _categories.indexOf(_categoryType);
    _activeCategoryIndex = ValueNotifier<int>(
      initialIndex >= 0 ? initialIndex : 0,
    );
    _visitedCategories = <AudioLibraryCategoryType>{_categoryType};
  }

  void _setLocalState(VoidCallback fn) => setState(fn);

  void _resetScroll() {
    final controller = _scrollControllers[_categoryType];
    if (controller != null && controller.hasClients) {
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
    FocusManager.instance.primaryFocus?.unfocus();
    _resetScroll();
    _visitedCategories.add(category);
    final targetIndex = _categories.indexOf(category);
    if (targetIndex >= 0) {
      _activeCategoryIndex.value = targetIndex;
    }
    final fromAll = _categoryType == AudioLibraryCategoryType.all;
    setState(() {
      _categoryType = category;
      _hasSwitchedCategory = true;
      _clearSelection();
      if (fromAll) {
        _animatingFromAll = true;
      }
    });
  }

  void _clearSelection() {
    _isSelectionMode = false;
    _selectedLibraryPaths.clear();
  }

  void _enterSelectionMode(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths
        ..clear()
        ..add(selectionKeyForLibraryNode(node));
    });
  }

  void _enterCategorySelectionMode(AudioLibraryCategoryEntry entry) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths
        ..clear()
        ..add(PathMatcher.normalize(entry.path));
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
      if (!_selectedLibraryPaths.add(key)) {
        _selectedLibraryPaths.remove(key);
        if (_selectedLibraryPaths.isEmpty) _isSelectionMode = false;
      }
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
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final blurEnabled = ref.watch(uiBlurEnabledProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    ref.watch(libraryListUiProvider.select((state) => state.structureRevision));
    ref.watch(libraryDetailRevisionProvider);
    final structureRevision = libraryFacade.structureRevision;
    final detailRevision = libraryFacade.detailCacheService.revision;
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

    final pinnedLibraryPaths = ref
        .watch(
          settingsStateProvider.select(
            (s) => s.value?.pinnedLibraryPaths ?? const <String>[],
          ),
        )
        .toSet();

    final body = AppFadeThroughIndexedStack(
      key: const ValueKey<String>('library_search_category_stack'),
      indexListenable: _activeCategoryIndex,
      style: AppIndexedStackTransitionStyle.slide,
      duration: kAppMotionSlow,
      onTransitionCompleted: (index) {
        if (_animatingFromAll && mounted) {
          setState(() => _animatingFromAll = false);
        }
      },
      children: [
        if (_visitedCategories.contains(AudioLibraryCategoryType.all))
          LibrarySearchAllResults(
            active: _categoryType == AudioLibraryCategoryType.all ||
                _animatingFromAll,
            query: _query,
            queryRevision: _queryRevision,
            structureRevision: structureRevision,
            detailRevision: detailRevision,
            scrollController:
                _scrollControllers[AudioLibraryCategoryType.all]!,
            topPadding: topInset,
            isSelectionMode: _isSelectionMode,
            selectedPaths: _selectedLibraryPaths,
            onEnterSelectionMode: _enterSelectionMode,
            onToggleSelection: _toggleLibrarySelection,
            onTreeChanged: (tree) => _searchSelectionTree = tree,
          )
        else
          const SizedBox.shrink(),
        for (final category in _categories.skip(1))
          if (_visitedCategories.contains(category))
            _buildCategoryBody(
              categoryType: category,
              libraryFacade: libraryFacade,
              i18n: i18n,
              topPadding: topInset,
              bottomPadding: MediaQuery.paddingOf(context).bottom + 16,
              cacheExtent: 320,
              structureRevision: structureRevision,
              detailRevision: detailRevision,
              pinnedPaths: pinnedLibraryPaths,
            )
          else
            const SizedBox.shrink(),
      ],
    );

    final isAllPinned =
        _selectedLibraryPaths.isNotEmpty &&
        _selectedLibraryPaths.every(
          (p) => pinnedLibraryPaths.contains(PathMatcher.normalize(p)),
        );

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
      blurEnabled: blurEnabled,
      body: HeroMode(
        key: const ValueKey<String>('library_search_hero_mode'),
        enabled: false,
        child: body,
      ),
      controlsOverlay: _isSelectionMode
          ? LibraryBatchSelectionHeader(
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
            )
          : null,
    );
  }

  Set<String> _selectedTermsForCategory(AudioLibraryCategoryType category) {
    return switch (category) {
      AudioLibraryCategoryType.tags => _selectedTagTerms,
      AudioLibraryCategoryType.voiceActors => _selectedVoiceActorTerms,
      AudioLibraryCategoryType.circles => _selectedCircleTerms,
      AudioLibraryCategoryType.all => const <String>{},
    };
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

  List<String> _termsForCategory(
    AudioLibraryCategorySnapshot snapshot,
    AudioLibraryCategoryType category,
  ) {
    final terms = switch (category) {
      AudioLibraryCategoryType.tags => snapshot.tagTerms,
      AudioLibraryCategoryType.voiceActors => snapshot.voiceActorTerms,
      AudioLibraryCategoryType.circles => snapshot.circleTerms,
      AudioLibraryCategoryType.all => const <String>[],
    };
    final keywords = _termSearchKeywordsForCategory(category);
    if (keywords.isEmpty) return terms;
    return terms.where((term) {
      final t = term.toLowerCase();
      return keywords.any((k) => t.contains(k));
    }).toList();
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
      AudioLibraryCategoryType.voiceActors =>
        i18n.tr('library_category_no_voice_actors'),
      AudioLibraryCategoryType.circles =>
        i18n.tr('library_category_no_circles'),
      AudioLibraryCategoryType.all => '',
    };
  }

  List<AudioLibraryCategoryEntry> _filterCategoryEntries(
    AudioLibraryCategorySnapshot snapshot,
    AudioLibraryCategoryType category, {
    Set<String> pinnedPaths = const <String>{},
  }) {
    final selectedTerms = _selectedTermsForCategory(category);
    final queryTerms = extractSearchTerms(
      _effectiveSearchQuery,
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
    final cache = _categoryFilterCaches.putIfAbsent(
      category,
      _CategoryFilterCache.new,
    );
    if (identical(snapshot, cache.snapshot) &&
        filterKey == cache.filterKey) {
      return cache.result;
    }

    final hasTextQuery = queryTerms.isNotEmpty;
    final hasElementQuery =
        normalizedSelectedTerms.isNotEmpty || termKeywords.isNotEmpty;

    final filtered = snapshot.entries
        .where((entry) {
          final entryTerms = entry.normalizedTermsForCategory(category);
          final matchesSelected = normalizedSelectedTerms.every(
            entryTerms.contains,
          );
          final matchesTermKeywords = termKeywords.every(
            (keyword) => entryTerms.any((term) => term.contains(keyword)),
          );
          final matchesElement =
              hasElementQuery && matchesSelected && matchesTermKeywords;
          final matchesText =
              hasTextQuery && queryTerms.every(entry.searchableText.contains);

          if (hasTextQuery && hasElementQuery) {
            return matchesText && matchesElement;
          } else if (hasTextQuery) {
            return matchesText;
          } else if (hasElementQuery) {
            return matchesElement;
          }
          return true;
        })
        .toList(growable: true);
    final normalizedPinned = pinnedPaths.isEmpty
        ? const <String>{}
        : pinnedPaths.map(PathMatcher.normalize).toSet();
    if (normalizedPinned.isNotEmpty) {
      filtered.sort((a, b) {
        final aPinned = normalizedPinned.contains(
          PathMatcher.normalize(a.path),
        );
        final bPinned = normalizedPinned.contains(
          PathMatcher.normalize(b.path),
        );
        if (aPinned != bPinned) return aPinned ? -1 : 1;
        return 0;
      });
    }
    final result = List<AudioLibraryCategoryEntry>.unmodifiable(filtered);
    cache.snapshot = snapshot;
    cache.filterKey = filterKey;
    cache.result = result;
    return result;
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
    return FutureBuilder<AudioLibraryCategorySnapshot>(
      key: ValueKey(
        'category_future_${categoryType.name}_${structureRevision}_$detailRevision',
      ),
      future: _categorySnapshotFuture,
      initialData:
          cachedSnapshot?.structureRevision == structureRevision &&
              cachedSnapshot?.detailRevision == detailRevision
          ? cachedSnapshot
          : null,
      builder: (context, snapshotState) {
        final snapshot = snapshotState.data;
        if (snapshot == null) {
          return PlaceholderContentTransition(
            showPlaceholder: true,
            placeholder: LibraryLoadingSkeleton(
              bottomInset: bottomPadding,
              topInset: topPadding,
            ),
            content: const SizedBox.shrink(),
          );
        }

        final terms = _termsForCategory(snapshot, categoryType);
        final entries = _filterCategoryEntries(
          snapshot,
          categoryType,
          pinnedPaths: pinnedPaths,
        );
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

        final hasTermBox = categoryType != AudioLibraryCategoryType.all;
        final itemCount = entries.length + (hasTermBox ? 1 : 0) + 1;
        final selectedTerms = _selectedTermsForCategory(categoryType);
        final termQuery = _termSearchQueries[categoryType] ?? '';

        final highlightTerms = <String>{
          ...extractSearchTerms(_effectiveSearchQuery),
          ...selectedTerms,
          ..._termSearchKeywordsForCategory(categoryType),
        }.where((t) => t.trim().isNotEmpty).toList(growable: false);

        final list = SearchHighlightScope.withTerms(
          terms: highlightTerms,
          child: ListView.builder(
            key: ValueKey('library_category_${categoryType.name}'),
            controller: _scrollControllers[categoryType]!,
            padding: EdgeInsets.fromLTRB(
              LibraryLikeCardMetrics.listHorizontalPadding,
              topPadding,
              LibraryLikeCardMetrics.listHorizontalPadding,
              bottomPadding,
            ),
            cacheExtent: cacheExtent,
            clipBehavior: Clip.none,
            physics: const ClampingScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (hasTermBox && index == 0) {
                return LibraryCategoryTermBox(
                  key: ValueKey('library_category_term_box_${categoryType.name}'),
                  categoryType: categoryType,
                  collapseOnMount: _hasSwitchedCategory &&
                      categoryType == _categoryType,
                  terms: terms,
                  selectedTerms: selectedTerms,
                  emptyText: _noTermsText(i18n, categoryType),
                  clearLabel: i18n.tr('clear'),
                  collapseLabel: i18n.tr('collapse'),
                  expandLabel: i18n.tr('expand'),
                  searchHintText: _termSearchHintText(i18n, categoryType),
                  searchQuery: termQuery,
                  onSearchQueryChanged: (val) {
                    _setLocalState(() {
                      if (val.isEmpty) {
                        _termSearchQueries.remove(categoryType);
                      } else {
                        _termSearchQueries[categoryType] = val;
                      }
                    });
                  },
                  onToggle: (term) {
                    _setLocalState(() {
                      if (!selectedTerms.remove(term)) selectedTerms.add(term);
                    });
                  },
                  onClear: () {
                    _setLocalState(() => selectedTerms.clear());
                  },
                );
              }

              final entryIndex = index - (hasTermBox ? 1 : 0);
              if (entryIndex == entries.length) {
                if (entries.isEmpty) {
                  return SizedBox(
                    height: 220,
                    child: Center(
                      child: Text(
                        i18n.tr('library_category_no_matches'),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink(key: ValueKey('category_bottom'));
              }

              final entry = entries[entryIndex];
              return RepaintBoundary(
                key: ValueKey('category_${entry.target.targetPath}'),
                child: AudioLibraryCategoryEntryCard(
                  entry: entry,
                  folder: folderForEntry(entry),
                  secondaryIcon: _categoryIcon(categoryType),
                  secondaryText: _entrySecondaryText(i18n, entry, categoryType),
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
          showPlaceholder: false,
          placeholder: LibraryLoadingSkeleton(
            bottomInset: bottomPadding,
            topInset: topPadding,
          ),
          content: list,
        );
      },
    );
  }
}
