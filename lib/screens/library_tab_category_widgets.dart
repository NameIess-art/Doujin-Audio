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
    required int detailRevision,
  }) {
    final topPadding = 4 + headerControlsFullHeight + 150;
    const bottomPadding = 350.0;
    return FutureBuilder<AudioLibraryCategorySnapshot>(
      key: ValueKey('category_future_${_categoryType.name}_$detailRevision'),
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
                clearLabel: i18n.tr('clear'),
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
            return WaterfallFlowStagger(
              key: ValueKey('category_${entry.target.targetPath}'),
              index: entryIndex,
              child: _AudioLibraryCategoryEntryCard(
                entry: entry,
                folder: _folderForCategoryEntry(provider, entry),
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
            onRefresh: _runLibraryPullRefresh,
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

  FolderNode? _folderForCategoryEntry(
    AudioProvider provider,
    AudioLibraryCategoryEntry entry,
  ) {
    if (!entry.isFolder) return null;
    for (final node in provider.libraryTree) {
      if (node is FolderNode &&
          PathMatcher.equalsNormalized(node.path, entry.path)) {
        return node;
      }
    }
    return null;
  }
}

class _LibraryCategoryTermBox extends StatelessWidget {
  const _LibraryCategoryTermBox({
    required this.terms,
    required this.selectedTerms,
    required this.emptyText,
    required this.clearLabel,
    required this.onToggle,
    required this.onClear,
  });

  final List<String> terms;
  final Set<String> selectedTerms;
  final String emptyText;
  final String clearLabel;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

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
                  .map<Widget>((term) {
                    final selected = selectedTerms.contains(term);
                    return GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onLongPress: () => _copyCategoryTerm(context, term),
                      child: FilterChip(
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
                      ),
                    );
                  })
                  .followedBy(<Widget>[
                    ActionChip(
                      avatar: const Icon(Icons.close_rounded, size: 16),
                      label: Text(clearLabel),
                      onPressed: selectedTerms.isEmpty ? null : onClear,
                      visualDensity: VisualDensity.compact,
                      backgroundColor: cs.surface,
                      side: BorderSide(color: cs.outlineVariant),
                      labelStyle: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(
                            color: selectedTerms.isEmpty
                                ? cs.onSurfaceVariant.withValues(alpha: 0.45)
                                : cs.primary,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ])
                  .toList(growable: false),
            ),
    );
  }

  void _copyCategoryTerm(BuildContext context, String term) {
    Clipboard.setData(ClipboardData(text: term));
    HapticFeedback.selectionClick();
    showAppSnackBar(
      context,
      context.read<AppLanguageProvider>().tr('copied_to_clipboard', {
        'value': term,
      }),
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

  String? _findParentLibraryPath(AudioProvider provider) {
    return provider.libraryRootForPath(entry.path);
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
    const cardHeight = _FolderNodeWidgetState._rootFolderTileHeight;
    final countText = i18n.tr('audio_count', {'count': entry.tracks.length});
    final folderNode = folder;

    if (entry.isFolder && folderNode != null) {
      return SwipeRevealCard(
        margin: const EdgeInsets.only(bottom: 6),
        shape: cardShape,
        actionLabel: i18n.tr('remove'),
        removeTooltip: i18n.tr('remove_audio_folder'),
        secondaryActionLabel: i18n.tr('audio_detail'),
        secondaryActionTooltip: i18n.tr('audio_detail'),
        verticalActions: true,
        onSecondaryAction: () =>
            unawaited(showAudioDetailSheet(context, entry.target)),
        onRemove: () => _remove(context, provider),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          color: cs.surface,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              minTileHeight: cardHeight,
              showTrailingIcon: false,
              tilePadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: _RootFolderCardContent(
                folderPath: entry.path,
                folderName: entry.title,
                detail: entry.detail,
                detailLoading: false,
                expanded: false,
                hasChildren: folderNode.children.isNotEmpty,
                onPlay: firstTrack == null
                    ? () {}
                    : () => _play(context, provider),
              ),
              children: folderNode.children
                  .map(
                    (childNode) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: RepaintBoundary(
                        child: _LibraryTreeItem(
                          key: ValueKey(childNode.path),
                          node: childNode,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      );
    }

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
        child: entry.isFolder
            ? SizedBox(
                height: cardHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: _AudioLibraryCategoryEntryTitle(
                          entry: entry,
                          secondaryIcon: secondaryIcon,
                          secondaryText: secondaryText,
                          countText: countText,
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
              )
            : firstTrack?.isVideo == true
            ? Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: SizedBox(
                  height: cardHeight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                    child: _SingleVideoFileCardContent(
                      track: firstTrack!,
                      title: entry.title,
                      detail: entry.detail,
                      detailLoading: false,
                      onPlay: () => _play(context, provider),
                    ),
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
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
    );
  }
}

class _AudioLibraryCategoryEntryTitle extends StatelessWidget {
  const _AudioLibraryCategoryEntryTitle({
    required this.entry,
    required this.secondaryIcon,
    required this.secondaryText,
    required this.countText,
  });

  final AudioLibraryCategoryEntry entry;
  final IconData secondaryIcon;
  final String secondaryText;
  final String countText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
          fontSize: 14,
          height: 1.06,
          color: cs.onSurface,
        ) ??
        const TextStyle();
    return Row(
      children: [
        if (entry.isFolder) ...[
          _LibraryCoverThumbnail(folderPath: entry.path),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LibraryLikeTwoLineMarqueeText(
                text: entry.title,
                style: titleStyle,
              ),
              const SizedBox(height: 5),
              _LibrarySecondaryInfoLine(
                icon: secondaryIcon,
                text: secondaryText,
              ),
              if (entry.isFolder) ...[
                const SizedBox(height: 4),
                _LibraryTertiaryInfoLine(
                  icon: Icons.library_music_rounded,
                  text: countText,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
