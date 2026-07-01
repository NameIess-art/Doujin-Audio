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
    required double topPadding,
    required double bottomPadding,
    required double cacheExtent,
    required bool canPullRefresh,
    required int detailRevision,
  }) {
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
            return RepaintBoundary(
              key: ValueKey('category_${entry.target.targetPath}'),
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

class _LibraryCategoryTermBox extends StatefulWidget {
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
  State<_LibraryCategoryTermBox> createState() => _LibraryCategoryTermBoxState();
}

class _LibraryCategoryTermBoxState extends State<_LibraryCategoryTermBox> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = AppPreferences.getBoolSync('library_category_terms_expanded') ?? false;
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      AppPreferences.setBool('library_category_terms_expanded', _expanded);
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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: widget.terms.isEmpty
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
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: _expanded ? double.infinity : 28.0,
                ),
                child: ClipRect(
                  child: Align(
                    alignment: Alignment.topLeft,
                    widthFactor: 1.0,
                    child: _FloatRightWrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: widget.terms
                          .map<Widget>((term) {
                            final selected = widget.selectedTerms.contains(term);
                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onLongPress: () => _copyCategoryTerm(context, term),
                              onSecondaryTap: () => _copyCategoryTerm(context, term),
                              child: SizedBox(
                                height: 28,
                                child: FilterChip(
                                  selected: selected,
                                  label: Text(term),
                                  onSelected: (_) => widget.onToggle(term),
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  padding: EdgeInsets.zero,
                                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                              ),
                            );
                          })
                          .followedBy(<Widget>[
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  height: 28,
                                  child: ActionChip(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.close_rounded, size: 14),
                                        const SizedBox(width: 2),
                                        Text(widget.clearLabel),
                                      ],
                                    ),
                                    onPressed: widget.selectedTerms.isEmpty ? null : widget.onClear,
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    padding: EdgeInsets.zero,
                                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                                    backgroundColor: cs.surface,
                                    side: BorderSide(color: cs.outlineVariant),
                                    labelStyle: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(
                                          color: widget.selectedTerms.isEmpty
                                              ? cs.onSurfaceVariant.withValues(alpha: 0.45)
                                              : cs.primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  height: 28,
                                  child: ActionChip(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                          size: 16,
                                          color: cs.primary,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(_expanded ? '收起' : '展开'),
                                      ],
                                    ),
                                    onPressed: _toggleExpanded,
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    padding: EdgeInsets.zero,
                                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                                    backgroundColor: cs.surface,
                                    side: BorderSide(color: cs.outlineVariant),
                                    labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ])
                          .toList(growable: false),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  void _copyCategoryTerm(BuildContext context, String term) {
    Clipboard.setData(ClipboardData(text: term));
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
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
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
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
        : ref.watch(activeTrackPathsProvider).contains(firstTrack.path);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
      borderRadius: BorderRadius.circular(14),
    );
    const cardHeight = _FolderNodeWidgetState._rootFolderTileHeight;
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
          color: cs.surfaceContainerLow,
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
                cs.surfaceContainerLow,
              )
            : cs.surfaceContainerLow,
        child: entry.isFolder
            ? SizedBox(
                height: cardHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                  child: _RootFolderCardContent(
                    folderPath: entry.path,
                    folderName: entry.title,
                    detail: entry.detail,
                    detailLoading: false,
                    expanded: false,
                    hasChildren: false,
                    onPlay: firstTrack == null
                        ? () {}
                        : () => _play(context, provider),
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
                padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
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

class _FloatRightWrap extends MultiChildRenderObjectWidget {
  const _FloatRightWrap({
    required super.children,
    this.spacing = 0.0,
    this.runSpacing = 0.0,
  });

  final double spacing;
  final double runSpacing;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderFloatRightWrap(spacing: spacing, runSpacing: runSpacing);
  }

  @override
  void updateRenderObject(BuildContext context, covariant _RenderFloatRightWrap renderObject) {
    renderObject
      ..spacing = spacing
      ..runSpacing = runSpacing;
  }
}

class _FloatRightWrapParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFloatRightWrap extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _FloatRightWrapParentData>,
         RenderBoxContainerDefaultsMixin<RenderBox, _FloatRightWrapParentData> {
  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (_spacing == value) return;
    _spacing = value;
    markNeedsLayout();
  }

  double _runSpacing;
  double get runSpacing => _runSpacing;
  set runSpacing(double value) {
    if (_runSpacing == value) return;
    _runSpacing = value;
    markNeedsLayout();
  }

  _RenderFloatRightWrap({required double spacing, required double runSpacing})
    : _spacing = spacing, _runSpacing = runSpacing;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FloatRightWrapParentData) {
      child.parentData = _FloatRightWrapParentData();
    }
  }

  @override
  void performLayout() {
    if (firstChild == null) {
      size = constraints.smallest;
      return;
    }

    RenderBox? floatChild = lastChild;
    if (floatChild == null) {
       size = constraints.smallest;
       return;
    }
    
    floatChild.layout(constraints.loosen(), parentUsesSize: true);
    final double floatWidth = floatChild.size.width;
    final double floatHeight = floatChild.size.height;

    double x = 0.0;
    double y = 0.0;
    double maxLineHeight = 0.0;
    double maxWidth = constraints.maxWidth;
    if (maxWidth.isInfinite) maxWidth = 400.0; // Fallback

    RenderBox? child = firstChild;
    while (child != null && child != floatChild) {
      child.layout(constraints.loosen(), parentUsesSize: true);

      double availableWidth = (y < floatHeight) ? (maxWidth - floatWidth - spacing) : maxWidth;

      if (x + child.size.width > availableWidth && x > 0.0) {
        x = 0.0;
        y += maxLineHeight + runSpacing;
        maxLineHeight = 0.0;
        availableWidth = (y < floatHeight) ? (maxWidth - floatWidth - spacing) : maxWidth;
      }

      final childParentData = child.parentData as _FloatRightWrapParentData;
      childParentData.offset = Offset(x, y);

      x += child.size.width + spacing;
      if (child.size.height > maxLineHeight) {
        maxLineHeight = child.size.height;
      }

      child = childParentData.nextSibling;
    }

    final floatParentData = floatChild.parentData as _FloatRightWrapParentData;
    floatParentData.offset = Offset(maxWidth - floatWidth, 0.0);

    double totalHeight = y + maxLineHeight;
    double finalHeight = totalHeight > floatHeight ? totalHeight : floatHeight;
    size = constraints.constrain(Size(maxWidth, finalHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
