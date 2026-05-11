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

  List<String> _termsForCategory(AudioLibraryCategorySnapshot snapshot) {
    return switch (_categoryType) {
      AudioLibraryCategoryType.tags => snapshot.tagTerms,
      AudioLibraryCategoryType.voiceActors => snapshot.voiceActorTerms,
      AudioLibraryCategoryType.circles => snapshot.circleTerms,
      AudioLibraryCategoryType.all => const <String>[],
    };
  }

  List<String> _entryTermsForCategory(AudioLibraryCategoryEntry entry) {
    return switch (_categoryType) {
      AudioLibraryCategoryType.tags => AudioLibraryCategorySnapshot.splitTerms(
        entry.detail.tags,
      ),
      AudioLibraryCategoryType.voiceActors =>
        AudioLibraryCategorySnapshot.splitTerms(entry.detail.voiceActors),
      AudioLibraryCategoryType.circles =>
        AudioLibraryCategorySnapshot.splitTerms([entry.detail.circleName]),
      AudioLibraryCategoryType.all => const <String>[],
    };
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
      AudioLibraryCategoryType.tags => AudioLibraryCategorySnapshot.splitTerms(
        entry.detail.tags,
      ),
      AudioLibraryCategoryType.voiceActors =>
        AudioLibraryCategorySnapshot.splitTerms(entry.detail.voiceActors),
      AudioLibraryCategoryType.circles =>
        AudioLibraryCategorySnapshot.splitTerms([entry.detail.circleName]),
      AudioLibraryCategoryType.all => [
        if (entry.detail.rjCode.trim().isNotEmpty)
          entry.detail.rjCode.trim()
        else
          i18n.tr('audio_detail_empty'),
      ],
    };
    return values.isEmpty ? i18n.tr('audio_detail_empty') : values.join('，');
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
    final normalizedQuery = _searchQuery.trim().toLowerCase();
    return snapshot.entries
        .where((entry) {
          if (selectedTerms.isNotEmpty) {
            final entryTerms = _entryTermsForCategory(entry).toSet();
            if (!selectedTerms.any(entryTerms.contains)) return false;
          }
          if (normalizedQuery.isNotEmpty &&
              !entry.searchableText.contains(normalizedQuery)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Widget _buildCategoryBody({
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required double headerControlsFullHeight,
    required double bottomInset,
    required double cacheExtent,
    required bool canPullRefresh,
  }) {
    final topPadding = 4 + headerControlsFullHeight + 150;
    final bottomPadding = bottomInset + 350;
    return FutureBuilder<AudioLibraryCategorySnapshot>(
      future: provider.audioLibraryCategorySnapshot(),
      initialData: provider.audioLibraryCategorySnapshotSync,
      builder: (context, snapshotState) {
        final snapshot = snapshotState.data;
        if (snapshot == null) {
          return _LibraryLoadingSkeleton(
            bottomInset: bottomPadding,
            topInset: topPadding,
          );
        }

        final terms = _termsForCategory(snapshot);
        final entries = _filterCategoryEntries(snapshot);
        final hasTermBox = _categoryType != AudioLibraryCategoryType.all;
        final itemCount = entries.length + (hasTermBox ? 1 : 0) + 1;

        Widget list = ListView.builder(
          key: ValueKey('library_category_${_categoryType.name}'),
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
          cacheExtent: cacheExtent,
          clipBehavior: Clip.none,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (hasTermBox && index == 0) {
              return _LibraryCategoryTermBox(
                terms: terms,
                selectedTerms: _selectedTermsForCurrentCategory,
                emptyText: _noTermsText(i18n),
                onToggle: (term) {
                  _setLocalState(() {
                    final selected = _selectedTermsForCurrentCategory;
                    if (!selected.remove(term)) selected.add(term);
                  });
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
            return WaterfallFlowStagger(
              key: ValueKey('category_${entry.target.targetPath}'),
              index: entryIndex,
              child: _AudioLibraryCategoryEntryCard(
                entry: entry,
                searchQuery: _searchQuery,
                secondaryIcon: _categoryIcon(),
                secondaryText: _entrySecondaryText(i18n, entry),
              ),
            );
          },
        );

        if (canPullRefresh) {
          list = RefreshIndicator(
            key: _refreshIndicatorKey,
            color: Theme.of(context).colorScheme.primary,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            onRefresh: () async {
              unawaited(HapticFeedback.mediumImpact());
              await _refreshWatchedFolders();
            },
            edgeOffset: topPadding,
            displacement: 32,
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            child: list,
          );
        }
        return list;
      },
    );
  }
}

class _LibraryCategoryTermBox extends StatelessWidget {
  const _LibraryCategoryTermBox({
    required this.terms,
    required this.selectedTerms,
    required this.emptyText,
    required this.onToggle,
  });

  final List<String> terms;
  final Set<String> selectedTerms;
  final String emptyText;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: terms.isEmpty
          ? Text(
              emptyText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            )
          : Wrap(
              spacing: 7,
              runSpacing: 7,
              children: terms
                  .map((term) {
                    final selected = selectedTerms.contains(term);
                    return FilterChip(
                      selected: selected,
                      label: Text(term),
                      onSelected: (_) => onToggle(term),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selectedColor: cs.secondaryContainer,
                      backgroundColor: cs.surface,
                      side: BorderSide(
                        color: selected
                            ? cs.secondary.withValues(alpha: 0.45)
                            : cs.outlineVariant,
                      ),
                      labelStyle: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(
                            color: selected
                                ? cs.onSecondaryContainer
                                : cs.onSurfaceVariant,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }
}

class _AudioLibraryCategoryEntryCard extends ConsumerWidget {
  const _AudioLibraryCategoryEntryCard({
    required this.entry,
    required this.searchQuery,
    required this.secondaryIcon,
    required this.secondaryText,
  });

  final AudioLibraryCategoryEntry entry;
  final String searchQuery;
  final IconData secondaryIcon;
  final String secondaryText;

  String? _findParentLibraryPath(AudioProvider provider) {
    for (final libraryPath in provider.watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(entry.path, libraryPath)) {
        return libraryPath;
      }
    }
    return null;
  }

  Future<void> _remove(BuildContext context, AudioProvider provider) async {
    final i18n = context.read<AppLanguageProvider>();
    final libraryPath = _findParentLibraryPath(provider);
    if (entry.isFolder) {
      if (libraryPath != null) {
        provider.setLibraryFolderExcluded(libraryPath, entry.path, true);
        if (context.mounted) {
          showAppSnackBar(
            context,
            i18n.tr('folder_excluded'),
            tone: AppFeedbackTone.warning,
            icon: Icons.block_rounded,
          );
        }
      } else {
        await provider.removeFolderFromLibrary(entry.path);
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
      provider.setLibraryTrackExcluded(libraryPath, entry.path, true);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('audio_excluded'),
          tone: AppFeedbackTone.warning,
          icon: Icons.block_rounded,
        );
      }
    } else {
      await provider.removeTrackFromLibrary(entry.path);
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

  void _play(BuildContext context, AudioProvider provider) {
    final track = entry.firstTrack;
    if (track == null) return;
    final i18n = context.read<AppLanguageProvider>();
    Feedback.forTap(context);
    unawaited(provider.spawnSession(track, autoPlay: true));
    _showSessionCreatedSnack(
      context,
      i18n.tr('session_created', {'name': track.displayName}),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final firstTrack = entry.firstTrack;
    final isAlreadyPlaying = firstTrack == null
        ? false
        : context.select<AudioProvider, bool>(
            (value) => value.isTrackActive(firstTrack.path),
          );
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: entry.isFolder
          ? i18n.tr('remove_audio_folder')
          : i18n.tr('remove_audio'),
      secondaryActionLabel: i18n.tr('audio_detail'),
      secondaryActionTooltip: i18n.tr('audio_detail'),
      onSecondaryAction: () =>
          unawaited(showAudioDetailSheet(context, entry.target)),
      onRemove: () => _remove(context, provider),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: isAlreadyPlaying
            ? Color.alphaBlend(
                cs.primaryContainer.withValues(alpha: 0.40),
                cs.surface,
              )
            : cs.surface,
        child: SizedBox(
          height: 82,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
            child: Row(
              children: [
                if (entry.isFolder) ...[
                  _LibraryCoverThumbnail(
                    folderPath: entry.path,
                    title: entry.title,
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _HighlightedText(
                        text: entry.title,
                        query: searchQuery,
                        maxLines: 1,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              height: 1.06,
                            ) ??
                            const TextStyle(),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: double.infinity,
                        height: 16,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                secondaryIcon,
                                size: 12,
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.65,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                secondaryText,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontStyle: FontStyle.italic,
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.65,
                                      ),
                                      fontSize: 9,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: firstTrack == null
                      ? null
                      : () => _play(context, provider),
                  style: IconButton.styleFrom(
                    foregroundColor: cs.primary,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_circle_rounded, size: 25),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
