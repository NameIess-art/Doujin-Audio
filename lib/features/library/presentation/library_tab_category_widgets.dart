part of 'library_tab.dart';

extension _LibraryTabCategoryView on _LibraryTabState {
  Set<String> get _selectedTermsForCurrentCategory {
    return switch (_categoryType) {
      AudioLibraryCategoryType.tags => _selectedTagTerms,
      AudioLibraryCategoryType.voiceActors => _selectedVoiceActorTerms,
      AudioLibraryCategoryType.circles => _selectedCircleTerms,
      AudioLibraryCategoryType.all => const <String>{},
    };
  }

  List<String> get _termSearchKeywords {
    return _termSearchQuery
        .toLowerCase()
        .split(RegExp(r'[\s,，;；|]+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _termsForCategory(AudioLibraryCategorySnapshot snapshot) {
    final terms = switch (_categoryType) {
      AudioLibraryCategoryType.tags => snapshot.tagTerms,
      AudioLibraryCategoryType.voiceActors => snapshot.voiceActorTerms,
      AudioLibraryCategoryType.circles => snapshot.circleTerms,
      AudioLibraryCategoryType.all => const <String>[],
    };
    final keywords = _termSearchKeywords;
    if (keywords.isEmpty) return terms;
    return terms.where((term) {
      final t = term.toLowerCase();
      return keywords.any((k) => t.contains(k));
    }).toList();
  }

  IconData _categoryIcon() {
    return switch (_categoryType) {
      AudioLibraryCategoryType.tags => Icons.sell_rounded,
      AudioLibraryCategoryType.voiceActors => Icons.record_voice_over_rounded,
      AudioLibraryCategoryType.circles => Icons.groups_rounded,
      AudioLibraryCategoryType.all => Icons.confirmation_number_rounded,
    };
  }

  String _entrySecondaryText(
    AppLanguageProvider i18n,
    AudioLibraryCategoryEntry entry,
  ) {
    final values = switch (_categoryType) {
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

  String _noTermsText(AppLanguageProvider i18n) {
    return switch (_categoryType) {
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

  List<AudioLibraryCategoryEntry> _filterCategoryEntries(
    AudioLibraryCategorySnapshot snapshot,
  ) {
    final selectedTerms = _selectedTermsForCurrentCategory;
    final normalizedQuery = _effectiveSearchQuery.trim().toLowerCase();
    final termKeywords = _termSearchKeywords;
    final normalizedSelectedTerms =
        selectedTerms.map((term) => term.toLowerCase()).toList(growable: false)
          ..sort();
    final filterKey = <String>[
      normalizedQuery,
      termKeywords.join('\n'),
      normalizedSelectedTerms.join('\n'),
    ].join('|');
    if (identical(snapshot, _lastCategoryFilterSnapshot) &&
        _categoryType == _lastCategoryFilterType &&
        filterKey == _lastCategoryFilterKey) {
      return _lastCategoryFilterResult;
    }

    final result = snapshot.entries
        .where((entry) {
          final entryTerms = entry.normalizedTermsForCategory(_categoryType);
          if (selectedTerms.isNotEmpty) {
            if (!normalizedSelectedTerms.any(entryTerms.contains)) return false;
          }
          if (termKeywords.isNotEmpty) {
            bool hasMatchingTerm = false;
            for (final term in entryTerms) {
              if (termKeywords.any(term.contains)) {
                hasMatchingTerm = true;
                break;
              }
            }
            if (!hasMatchingTerm) return false;
          }
          if (normalizedQuery.isNotEmpty &&
              !entry.searchableText.contains(normalizedQuery)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    _lastCategoryFilterSnapshot = snapshot;
    _lastCategoryFilterType = _categoryType;
    _lastCategoryFilterKey = filterKey;
    _lastCategoryFilterResult = result;
    return result;
  }

  String _termSearchHintText(AppLanguageProvider i18n) {
    final searchPrefix = i18n.tr('search');
    return switch (_categoryType) {
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
    required LibraryFacade libraryFacade,
    required AppLanguageProvider i18n,
    required double topPadding,
    required double bottomPadding,
    required double cacheExtent,
    required bool canPullRefresh,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
  }) {
    return FutureBuilder<AudioLibraryCategorySnapshot>(
      key: ValueKey('category_future_${_categoryType.name}_$detailRevision'),
      future: libraryFacade.audioLibraryCategorySnapshot(),
      initialData: libraryFacade.categorySnapshot,
      builder: (context, snapshotState) {
        final snapshot = snapshotState.data;
        if (snapshot == null) {
          return PlaceholderContentTransition(
            showPlaceholder: true,
            placeholder: _LibraryLoadingSkeleton(
              bottomInset: bottomPadding,
              topInset: topPadding,
            ),
            content: const SizedBox.shrink(),
          );
        }

        final terms = _termsForCategory(snapshot);
        final entries = _filterCategoryEntries(snapshot);
        _scheduleLibraryCoverWarmup(
          libraryFacade: libraryFacade,
          tracks: entries.map((entry) => entry.firstTrack),
          structureRevision: structureRevision,
          detailRevision: detailRevision,
          coverGeneration: coverGeneration,
          scope: _categoryType.name,
        );
        final hasTermBox = _categoryType != AudioLibraryCategoryType.all;
        final itemCount = entries.length + (hasTermBox ? 1 : 0) + 1;

        Widget list = ListView.builder(
          key: ValueKey('library_category_${_categoryType.name}'),
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
          cacheExtent: cacheExtent,
          clipBehavior: Clip.none,
          physics: canPullRefresh
              ? const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                )
              : const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (hasTermBox && index == 0) {
              return _LibraryCategoryTermBox(
                categoryType: _categoryType,
                terms: terms,
                selectedTerms: _selectedTermsForCurrentCategory,
                emptyText: _noTermsText(i18n),
                clearLabel: i18n.tr('clear'),
                searchHintText: _termSearchHintText(i18n),
                searchQuery: _termSearchQuery,
                onSearchQueryChanged: (val) {
                  _setLocalState(() => _termSearchQuery = val);
                },
                onToggle: (term) {
                  _setLocalState(() {
                    final selected = _selectedTermsForCurrentCategory;
                    if (!selected.remove(term)) selected.add(term);
                  });
                },
                onClear: () {
                  _setLocalState(
                    () => _selectedTermsForCurrentCategory.clear(),
                  );
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
              child: _AudioLibraryCategoryEntryCard(
                entry: entry,
                folder: _folderForCategoryEntry(libraryFacade, entry),
                secondaryIcon: _categoryIcon(),
                secondaryText: _entrySecondaryText(i18n, entry),
              ),
            );
          },
        );

        if (canPullRefresh) {
          list = GlassRefreshIndicator(
            key: _refreshIndicatorKey,
            color: Theme.of(context).colorScheme.primary,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            onRefresh: _runLibraryPullRefresh,
            edgeOffset: topPadding,
            displacement: 32,
            triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
            child: list,
          );
        }
        return PlaceholderContentTransition(
          showPlaceholder: false,
          placeholder: _LibraryLoadingSkeleton(
            bottomInset: bottomPadding,
            topInset: topPadding,
          ),
          content: list,
        );
      },
    );
  }

  FolderNode? _folderForCategoryEntry(
    LibraryFacade libraryFacade,
    AudioLibraryCategoryEntry entry,
  ) {
    if (!entry.isFolder) return null;
    for (final folder in libraryFacade.libraryCards.whereType<FolderNode>()) {
      if (PathMatcher.equalsNormalized(folder.path, entry.path)) return folder;
    }
    return null;
  }
}

class _LibraryCategoryTermBox extends StatefulWidget {
  const _LibraryCategoryTermBox({
    required this.categoryType,
    required this.terms,
    required this.selectedTerms,
    required this.emptyText,
    required this.clearLabel,
    required this.onToggle,
    required this.onClear,
    required this.searchHintText,
    required this.searchQuery,
    required this.onSearchQueryChanged,
  });

  final AudioLibraryCategoryType categoryType;
  final List<String> terms;
  final Set<String> selectedTerms;
  final String emptyText;
  final String clearLabel;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;
  final String searchHintText;
  final String searchQuery;
  final ValueChanged<String> onSearchQueryChanged;

  @override
  State<_LibraryCategoryTermBox> createState() =>
      _LibraryCategoryTermBoxState();
}

class _LibraryCategoryTermBoxState extends State<_LibraryCategoryTermBox> {
  static const _searchDebounce = Duration(milliseconds: 180);
  bool _expanded = false;
  bool _wasExpandedBeforeSearch = false;
  late final TextEditingController _searchController;
  late final String _prefKey;
  late String _localSearchQuery;
  Timer? _searchDebounceTimer;

  @override
  void initState() {
    super.initState();
    _prefKey = 'library_category_terms_expanded_${widget.categoryType.name}';
    _expanded = AppPreferences.getBoolSync(_prefKey) ?? false;
    _searchController = TextEditingController(text: widget.searchQuery);
    _localSearchQuery = widget.searchQuery;
  }

  void _onSearchQueryChangedLocally(String val) {
    final previous = _localSearchQuery;
    _localSearchQuery = val;
    if (previous.isEmpty && val.isNotEmpty) {
      _wasExpandedBeforeSearch = _expanded;
      if (!_expanded) {
        setState(() {
          _expanded = true;
          AppPreferences.setBool(_prefKey, _expanded);
        });
      }
    } else if (previous.isNotEmpty && val.isEmpty) {
      if (!_wasExpandedBeforeSearch && _expanded) {
        setState(() {
          _expanded = false;
          AppPreferences.setBool(_prefKey, _expanded);
        });
      }
    }
    _searchDebounceTimer?.cancel();
    if (val.isEmpty) {
      widget.onSearchQueryChanged(val);
    } else {
      _searchDebounceTimer = Timer(
        _searchDebounce,
        () => widget.onSearchQueryChanged(_localSearchQuery),
      );
    }
  }

  void _onClearSearchLocally() {
    _searchController.clear();
    _onSearchQueryChangedLocally('');
  }

  @override
  void didUpdateWidget(covariant _LibraryCategoryTermBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery &&
        _searchController.text != widget.searchQuery) {
      _searchController.text = widget.searchQuery;
      _localSearchQuery = widget.searchQuery;
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      AppPreferences.setBool(_prefKey, _expanded);
      if (_localSearchQuery.isNotEmpty) {
        _wasExpandedBeforeSearch = _expanded;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: widget.terms.isEmpty && _localSearchQuery.isEmpty
          ? Text(
              widget.emptyText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            )
          : AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 28,
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchQueryChangedLocally,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                            decoration: InputDecoration(
                              hintText: widget.searchHintText,
                              hintStyle: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.6,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                              contentPadding: const EdgeInsets.only(
                                left: 10,
                                bottom: 14,
                              ),
                              filled: true,
                              fillColor: cs.surface,
                              isDense: true,
                              suffixIcon: _localSearchQuery.isNotEmpty
                                  ? GestureDetector(
                                      onTap: _onClearSearchLocally,
                                      behavior: HitTestBehavior.opaque,
                                      child: Icon(
                                        Icons.cancel_rounded,
                                        size: 14,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    )
                                  : null,
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cs.outlineVariant,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(color: cs.primary),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (widget.selectedTerms.isNotEmpty) ...[
                        SizedBox(
                          height: 28,
                          child: ActionChip(
                            label: Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.close_rounded, size: 14),
                                  const SizedBox(width: 2),
                                  Text(widget.clearLabel),
                                ],
                              ),
                            ),
                            onPressed: widget.onClear,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            padding: EdgeInsets.zero,
                            labelPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                            ),
                            backgroundColor: cs.surface,
                            side: BorderSide(color: cs.outlineVariant),
                            labelStyle: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      SizedBox(
                        height: 28,
                        child: ActionChip(
                          label: Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _expanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  size: 16,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 2),
                                Text(_expanded ? '收起' : '展开'),
                              ],
                            ),
                          ),
                          onPressed: _toggleExpanded,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                          ),
                          backgroundColor: cs.surface,
                          side: BorderSide(color: cs.outlineVariant),
                          labelStyle: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                    ],
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: widget.terms
                          .map<Widget>((term) {
                            final selected = widget.selectedTerms.contains(
                              term,
                            );
                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onLongPress:
                                  defaultTargetPlatform ==
                                      TargetPlatform.android
                                  ? () => _copyCategoryTerm(context, term)
                                  : null,
                              onSecondaryTap:
                                  defaultTargetPlatform ==
                                      TargetPlatform.windows
                                  ? () => _copyCategoryTerm(context, term)
                                  : null,
                              child: SizedBox(
                                height: 28,
                                child: FilterChip(
                                  selected: selected,
                                  label: Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(term),
                                  ),
                                  onSelected: (_) => widget.onToggle(term),
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: EdgeInsets.zero,
                                  labelPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  selectedColor: cs.secondaryContainer,
                                  backgroundColor: cs.surface,
                                  side: BorderSide(
                                    color: selected
                                        ? cs.secondary.withValues(alpha: 0.45)
                                        : cs.outlineVariant,
                                  ),
                                  labelStyle: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: selected
                                            ? cs.onSecondaryContainer
                                            : cs.onSurfaceVariant,
                                        fontWeight: selected
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                ),
                              ),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  void _copyCategoryTerm(BuildContext context, String term) {
    Clipboard.setData(ClipboardData(text: term));
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    showAppSnackBar(
      context,
      ProviderScope.containerOf(context, listen: false)
          .read(appLanguageProviderInstanceProvider)
          .tr('copied_to_clipboard', {'value': term}),
      icon: Icons.content_copy_rounded,
    );
  }
}

class _AudioLibraryCategoryEntryCard extends ConsumerWidget {
  const _AudioLibraryCategoryEntryCard({
    required this.entry,
    required this.folder,
    required this.secondaryIcon,
    required this.secondaryText,
  });

  final AudioLibraryCategoryEntry entry;
  final FolderNode? folder;
  final IconData secondaryIcon;
  final String secondaryText;

  String? _findParentLibraryPath(LibraryFacade library) {
    return library.libraryRootForPath(entry.path);
  }

  Future<void> _remove(BuildContext context, LibraryFacade library) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryPath = _findParentLibraryPath(library);
    if (entry.isFolder) {
      if (libraryPath != null) {
        library.excludeLibraryFolder(libraryPath, entry.path);
        if (context.mounted) {
          showAppSnackBar(
            context,
            i18n.tr('folder_excluded'),
            tone: AppFeedbackTone.warning,
            icon: Icons.block_rounded,
          );
        }
      } else {
        await library.removeFolderFromLibrary(entry.path);
        if (context.mounted) {
          showAppSnackBar(
            context,
            i18n.tr('folder_removed'),
            tone: AppFeedbackTone.destructive,
            icon: Icons.delete_outline_rounded,
          );
        }
      }
      return;
    }

    if (libraryPath != null) {
      library.excludeLibraryTrack(libraryPath, entry.path);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('audio_excluded'),
          tone: AppFeedbackTone.warning,
          icon: Icons.block_rounded,
        );
      }
    } else {
      await library.removeTrackFromLibrary(entry.path);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('audio_removed'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.delete_outline_rounded,
        );
      }
    }
  }

  void _play(BuildContext context, PlaybackFacade playback) {
    final track = entry.firstTrack;
    if (track == null) return;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    unawaited(playback.spawnSession(track, autoPlay: true));
    _showSessionCreatedSnack(
      context,
      i18n.tr('session_created', {'name': track.displayName}),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final playback = ref.read(playbackFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final firstTrack = entry.firstTrack;
    final isAlreadyPlaying = firstTrack == null
        ? false
        : ref.watch(isTrackActiveProvider(firstTrack.path));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardShape = LibraryLikeCardMetrics.cardShape(
      cs,
      borderAlpha: isDark ? 0.26 : 0.42,
    );
    const cardHeight = _FolderNodeWidgetState._rootFolderTileHeight;
    final folderNode = folder;

    if (entry.isFolder && folderNode != null) {
      return _FolderNodeWidget(
        folder: folderNode,
        initiallyExpanded: false,
        searchQuery: '',
      );
    }

    Widget buildEntryCard(bool useFeaturedCard) {
      return SwipeRevealCard(
        margin: const EdgeInsets.only(bottom: 6),
        shape: cardShape,
        actionLabel: i18n.tr('remove'),
        removeTooltip: entry.isFolder
            ? i18n.tr('remove_audio_folder')
            : i18n.tr('remove_audio'),
        secondaryActionLabel: i18n.tr('audio_detail'),
        secondaryActionTooltip: i18n.tr('audio_detail'),
        verticalActions: useFeaturedCard,
        onSecondaryAction: () =>
            unawaited(showAudioDetailSheet(context, entry.target)),
        onRemove: () => _remove(context, library),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          color: isAlreadyPlaying
              ? Color.alphaBlend(
                  cs.primaryContainer.withValues(alpha: 0.40),
                  cs.surfaceContainerLow,
                )
              : cs.surfaceContainerLow,
          child: _buildEntryContent(
            context,
            library,
            playback,
            firstTrack,
            cardHeight,
            useFeaturedCardOverride: useFeaturedCard,
          ),
        ),
      );
    }

    if (!entry.isFolder && firstTrack != null) {
      final resolvedCoverPath = library.resolvedCoverPathForTrack(firstTrack);
      final useFeaturedCard =
          firstTrack.isVideo ||
          hasDisplayableCoverArtwork(firstTrack, resolvedCoverPath);
      return buildEntryCard(useFeaturedCard);
    }

    return buildEntryCard(entry.isFolder);
  }

  Widget _buildEntryContent(
    BuildContext context,
    LibraryFacade library,
    PlaybackFacade playback,
    MusicTrack? firstTrack,
    double cardHeight, {
    bool? useFeaturedCardOverride,
  }) {
    if (entry.isFolder) {
      return SizedBox(
        height: cardHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: _RootFolderCardContent(
            folderPath: entry.path,
            folderName: entry.title,
            folderDuration: folder?.totalDuration ?? Duration.zero,
            detail: entry.detail,
            detailLoading: false,
            expanded: false,
            hasChildren: false,
            onPlay: firstTrack == null ? () {} : () => _play(context, playback),
          ),
        ),
      );
    }

    Widget buildSingleFileContent(bool useFeaturedCard) {
      if (firstTrack != null && useFeaturedCard) {
        return ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          minTileHeight: cardHeight,
          title: _SingleMediaFileCardContent(
            track: firstTrack,
            title: entry.title,
            detail: entry.detail,
            detailLoading: false,
            onPlay: () => _play(context, playback),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
        child: Row(
          children: [
            Expanded(
              child: _SingleAudioFileCardContent(
                title: entry.title,
                detail: entry.detail,
                detailLoading: false,
              ),
            ),
            IconButton(
              onPressed: firstTrack == null
                  ? null
                  : () => _play(context, playback),
              style: IconButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                minimumSize: const Size(40, 44),
                maximumSize: const Size(40, 44),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.add_circle_rounded, size: 25),
            ),
          ],
        ),
      );
    }

    if (firstTrack == null) return buildSingleFileContent(false);
    final resolvedCoverPath = library.resolvedCoverPathForTrack(firstTrack);
    final useFeaturedCard =
        useFeaturedCardOverride ??
        (firstTrack.isVideo ||
            hasDisplayableCoverArtwork(firstTrack, resolvedCoverPath));
    return buildSingleFileContent(useFeaturedCard);
  }
}
