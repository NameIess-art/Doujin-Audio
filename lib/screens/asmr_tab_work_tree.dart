part of 'asmr_tab.dart';

class _AsmrWorkTreeCard extends StatefulWidget {
  const _AsmrWorkTreeCard({required this.work, required this.searchQuery});

  final AsmrWork work;
  final String searchQuery;

  @override
  State<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends State<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = LibraryLikeCardMetrics.rootTileHeight;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  Future<void> _playWork(BuildContext context) async {
    final asmrController = context.read<AsmrLibraryController>();
    await asmrController.playWork(context.read<AudioProvider>(), widget.work);
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': widget.work.title}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final shouldFavorite = !widget.work.isFavorite;
    unawaited(controller.toggleFavorite(widget.work));
    showAppSnackBar(
      context,
      i18n.tr(shouldFavorite ? 'asmr_favorite_added' : 'asmr_favorite_removed'),
      tone: shouldFavorite ? AppFeedbackTone.success : AppFeedbackTone.warning,
      icon: shouldFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _openDownloadPage(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(buildAppPageRoute<void>(child: AsmrDownloadPage(work: widget.work)));
  }

  @override
  Widget build(BuildContext context) {
    final treeState = context
        .select<AsmrLibraryController, AsmrTrackTreeViewState>(
          (controller) => controller.trackTreeViewState(widget.work.id),
        );
    final tree = treeState.tree;
    final visibleTree = treeState.visibleTree;
    final isTreeLoading = treeState.isLoading;
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.cardRadius),
    );

    return SwipeRevealCard(
      shape: cardShape,
      actionLabel: i18n.tr('asmr_detail_action'),
      removeTooltip: i18n.tr('asmr_detail_tooltip'),
      primaryActionTooltip: i18n.tr('asmr_detail_action'),
      primaryActionIcon: Icons.info_outline_rounded,
      destructive: false,
      secondaryActionLabel: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_favorite_action',
      ),
      secondaryActionTooltip: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_add_favorite_tooltip',
      ),
      secondaryActionIcon: widget.work.isFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      tertiaryActionLabel: i18n.tr('asmr_download_action'),
      tertiaryActionTooltip: i18n.tr('asmr_download_work_tooltip'),
      verticalActions: true,
      onTertiaryAction: () => unawaited(_openDownloadPage(context)),
      onSecondaryAction: () => unawaited(_toggleFavorite(context)),
      onRemove: () => unawaited(showAsmrWorkDetailSheet(context, widget.work)),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.hardEdge,
        shape: cardShape,
        color: cs.surfaceContainerLow,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            minTileHeight: _rootTileHeight,
            onExpansionChanged: (expanded) {
              if (_expanded == expanded) {
                return;
              }
              setState(() {
                _expanded = expanded;
              });
              if (expanded && tree == null && !isTreeLoading) {
                unawaited(
                  context.read<AsmrLibraryController>().ensureTrackTree(
                    widget.work,
                  ),
                );
              }
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                LibraryLikeCardMetrics.cardRadius,
              ),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                LibraryLikeCardMetrics.cardRadius,
              ),
            ),
            showTrailingIcon: false,
            tilePadding: LibraryLikeCardMetrics.rootTilePadding,
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
            title: _AsmrRootCardContent(
              work: widget.work,
              expanded: _expanded,
              hasChildren: (visibleTree?.isNotEmpty ?? false) || isTreeLoading,
              onPlay: () => unawaited(_playWork(context)),
            ),
            children: [
              if (isTreeLoading && visibleTree == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: asmrBlue,
                    ),
                  ),
                )
              else if (visibleTree == null || visibleTree.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    i18n.tr('asmr_empty_track_tree'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                for (final node in visibleTree)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _AsmrTrackTreeNode(
                      work: widget.work,
                      node: node,
                      searchQuery: widget.searchQuery,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrRootCardContent extends StatelessWidget {
  const _AsmrRootCardContent({
    required this.work,
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
  });

  final AsmrWork work;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.watch<AppLanguageProvider>();
    return LibraryLikeFeaturedCardContent(
      title: work.title,
      lines: _workInfoLines(context, work),
      coverBuilder: (coverWidth) =>
          _AsmrWorkCover(url: _asmrWorkListCoverUrl(work), width: coverWidth),
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: true,
      playTooltip: i18n.tr('asmr_add_to_playlist'),
      accentColor: asmrBlue,
      enableMarquee: false,
      enableTitleMarquee: false,
    );
  }
}

class _AsmrTrackTreeNode extends StatefulWidget {
  const _AsmrTrackTreeNode({
    required this.work,
    required this.node,
    required this.searchQuery,
  });

  final AsmrWork work;
  final AsmrTrackFile node;
  final String searchQuery;

  @override
  State<_AsmrTrackTreeNode> createState() => _AsmrTrackTreeNodeState();
}

class _AsmrTrackTreeNodeState extends State<_AsmrTrackTreeNode> {
  static const double _childFolderTileHeight = 44;
  static const double _childFolderTitleBlockHeight = 36;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.node.isFolder) {
      final hasVisibleChildren = widget.node.children.any(
        (child) => child.hasBrowsableContent,
      );
      final visibleChildren = widget.node.children
          .where((child) => child.hasBrowsableContent)
          .toList(growable: false);
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final asmrBlue = isDark
          ? const Color(0xFF60A5FA)
          : const Color(0xFF1D4ED8);
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          controller: _expansionController,
          minTileHeight: _childFolderTileHeight,
          onExpansionChanged: (expanded) {
            if (_expanded == expanded) {
              return;
            }
            setState(() {
              _expanded = expanded;
            });
          },
          shape: const RoundedRectangleBorder(),
          collapsedShape: const RoundedRectangleBorder(),
          showTrailingIcon: false,
          tilePadding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
          title: Row(
            children: [
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: asmrBlue.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: _childFolderTitleBlockHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              height: 1.06,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          trailing: SizedBox(
            width: 62,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: () => unawaited(_playFolder(context)),
                  visualDensity: VisualDensity.compact,
                  tooltip: context.watch<AppLanguageProvider>().tr(
                    'asmr_add_to_playlist',
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: asmrBlue,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_circle_rounded, size: 25),
                ),
                const SizedBox(width: 2),
                if (hasVisibleChildren)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IgnorePointer(
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          children: [
            for (final child in visibleChildren)
              Padding(
                padding: EdgeInsets.zero,
                child: _AsmrTrackTreeNode(
                  work: widget.work,
                  node: child,
                  searchQuery: widget.searchQuery,
                ),
              ),
          ],
        ),
      );
    }
    return _AsmrTrackLeafRow(work: widget.work, node: widget.node);
  }

  Future<void> _playFolder(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final provider = context.read<AudioProvider>();
    final tracks = controller.buildPlayableTracksFromNode(
      widget.work,
      widget.node,
    );
    if (!context.mounted || tracks.isEmpty) {
      return;
    }
    await controller.recordHistory(widget.work);
    await provider.spawnSessionWithQueue(
      tracks,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': widget.node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrTrackLeafRow extends StatelessWidget {
  const _AsmrTrackLeafRow({required this.work, required this.node});

  final AsmrWork work;
  final AsmrTrackFile node;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return ColoredBox(
      color: cs.surfaceContainerLow,
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(
                Icons.audio_file_rounded,
                size: 16,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  node.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Text(
                _formatDuration(node.duration),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => unawaited(_playTrack(context)),
                style: IconButton.styleFrom(
                  foregroundColor: asmrBlue,
                  minimumSize: const Size(36, 36),
                  maximumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.add_circle_rounded, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playTrack(BuildContext context) async {
    await context.read<AsmrLibraryController>().playTrack(
      context.read<AudioProvider>(),
      work,
      node,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

List<LibraryLikeInfoLineData> _workInfoLines(
  BuildContext context,
  AsmrWork work,
) {
  final i18n = context.read<AppLanguageProvider>();
  final fields = context.select<AudioProvider, List<CardInfoField>>(
    (provider) => provider.cardInfoFields,
  );
  final result = <LibraryLikeInfoLineData>[];
  for (final field in fields) {
    switch (field) {
      case CardInfoField.rjCode:
        if (work.rjCode.trim().isNotEmpty) {
          result.add(LibraryLikeInfoLineData('RJ', work.rjCode));
        }
        break;
      case CardInfoField.voiceActors:
        if (work.voiceActors.isNotEmpty) {
          result.add(LibraryLikeInfoLineData('CV', work.voiceActors.join('、')));
        }
        break;
      case CardInfoField.circleName:
        if (work.circleName.trim().isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(
              i18n.tr('asmr_circle_label'),
              work.circleName.trim(),
            ),
          );
        }
        break;
      case CardInfoField.tags:
        if (work.tags.isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(
              i18n.tr('asmr_tags_label'),
              work.tags.join('、'),
              lines: CardInfoField.tagLineCountForSelection(fields.length),
            ),
          );
        }
        break;
      case CardInfoField.releaseDate:
        final value = _formatAsmrCardDate(work.releaseDate);
        if (value.isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(i18n.tr('card_info_release_date'), value),
          );
        }
        break;
      case CardInfoField.salesCount:
        if (work.dlCount > 0) {
          result.add(
            LibraryLikeInfoLineData(
              i18n.tr('card_info_sales_count'),
              work.dlCount.toString(),
            ),
          );
        }
        break;
      case CardInfoField.rating:
        final value = _formatAsmrCardRating(work.rating);
        if (value.isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(i18n.tr('card_info_rating'), value),
          );
        }
        break;
    }
  }
  return result;
}

String _formatAsmrCardDate(DateTime? value) {
  if (value == null) return '';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String _formatAsmrCardRating(double value) {
  if (value <= 0) return '';
  return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1);
}

String _formatDuration(Duration value) {
  if (value == Duration.zero) {
    return '--:--';
  }
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
