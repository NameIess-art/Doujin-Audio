part of 'library_tab.dart';

class _LibraryTreeItem extends StatelessWidget {
  const _LibraryTreeItem({super.key, required this.node});

  final LibraryNode node;

  @override
  Widget build(BuildContext context) {
    if (node is FolderNode) {
      return _FolderNodeWidget(folder: node as FolderNode);
    } else if (node is TrackNode) {
      return _TrackNodeWidget(trackNode: node as TrackNode);
    }
    return const SizedBox.shrink();
  }
}

class _FolderNodeWidget extends StatefulWidget {
  const _FolderNodeWidget({required this.folder});

  final FolderNode folder;

  @override
  State<_FolderNodeWidget> createState() => _FolderNodeWidgetState();
}

class _FolderNodeWidgetState extends State<_FolderNodeWidget> {
  static const double _rootFolderTileHeight = 70;
  static const double _childFolderTileHeight = 62;
  static const double _rootFolderTitleBlockHeight = 34;
  static const double _childFolderTitleBlockHeight = 50;

  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  Future<void> _removeFolder(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    await provider.removeFolderFromLibrary(widget.folder.path);
    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('folder_removed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  void _playFolder(BuildContext context, AudioProvider provider) {
    final i18n = context.read<AppLanguageProvider>();
    final firstTrack = widget.folder.firstTrack;
    if (firstTrack == null) return;
    Feedback.forTap(context);
    unawaited(provider.spawnSession(firstTrack));
    _showSessionCreatedSnack(
      context,
      i18n.tr('session_created', {'name': firstTrack.displayName}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final cs = Theme.of(context).colorScheme;
    final isRootFolder = widget.folder.depth == 0;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );
    final groupLabel = isRootFolder
        ? ''
        : path.basename(path.dirname(widget.folder.path));

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio_folder'),
      onRemove: () => _removeFolder(context, provider),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: cs.surface,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            minTileHeight: isRootFolder
                ? _rootFolderTileHeight
                : _childFolderTileHeight,
            onExpansionChanged: (expanded) {
              if (_expanded == expanded) return;
              setState(() {
                _expanded = expanded;
              });
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            tilePadding: EdgeInsets.fromLTRB(isRootFolder ? 12 : 10, 2, 4, 2),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            title: Row(
              children: [
                if (isRootFolder) ...[
                  _LibraryCoverThumbnail(
                    coverPathFuture: provider.coverPathFutureForFolder(
                      widget.folder.path,
                    ),
                    title: widget.folder.name,
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: isRootFolder
                            ? _rootFolderTitleBlockHeight
                            : _childFolderTitleBlockHeight,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (groupLabel.isNotEmpty) ...[
                              Text(
                                groupLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.65,
                                      ),
                                      fontWeight: FontWeight.w500,
                                      fontSize: 10,
                                    ),
                              ),
                              const SizedBox(height: 3),
                            ],
                            Text(
                              widget.folder.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                    height: 1.06,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (isRootFolder) ...[
                        const SizedBox(height: 4),
                        SizedBox(
                          width: double.infinity,
                          child: _LibraryMetaChip(
                            icon: Icons.library_music_rounded,
                            text: i18n.tr('audio_count', {
                              'count': widget.folder.totalTrackCount,
                            }),
                          ),
                        ),
                      ],
                    ],
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
                    onPressed: () => _playFolder(context, provider),
                    visualDensity: VisualDensity.compact,
                    tooltip: i18n.tr('play'),
                    style: IconButton.styleFrom(
                      foregroundColor: cs.primary,
                      minimumSize: const Size(40, 44),
                      maximumSize: const Size(40, 44),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.add_rounded, size: 24),
                  ),
                  const SizedBox(width: 2),
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
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            children: widget.folder.children
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
}

class _TrackNodeWidget extends StatelessWidget {
  const _TrackNodeWidget({required this.trackNode});

  final TrackNode trackNode;

  Future<void> _removeTrack(
    BuildContext context,
    AudioProvider provider,
    MusicTrack track,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    await provider.removeTrackFromLibrary(track.path);
    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('audio_removed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final cs = Theme.of(context).colorScheme;
    final track = trackNode.track;
    final isAlreadyPlaying = context.select<AudioProvider, bool>(
      (value) => value.isTrackActive(track.path),
    );
    final cardShape = RoundedRectangleBorder(
      side: track.isSingle
          ? BorderSide(color: cs.outlineVariant)
          : BorderSide.none,
      borderRadius: BorderRadius.circular(14),
    );

    if (track.isSingle) {
      return SwipeRevealCard(
        margin: const EdgeInsets.only(bottom: 6),
        shape: cardShape,
        actionLabel: i18n.tr('remove'),
        removeTooltip: i18n.tr('remove_audio'),
        onRemove: () => _removeTrack(context, provider, track),
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
            height: 70,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          track.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                                height: 1.06,
                              ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          width: double.infinity,
                          child: _LibraryMetaChip(
                            icon: Icons.upload_file_rounded,
                            text: i18n.tr('file_added'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Feedback.forTap(context);
                      unawaited(provider.spawnSession(track));
                      _showSessionCreatedSnack(
                        context,
                        i18n.tr('session_created', {'name': track.displayName}),
                      );
                    },
                    style: IconButton.styleFrom(
                      foregroundColor: cs.primary,
                      minimumSize: const Size(40, 44),
                      maximumSize: const Size(40, 44),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.add_rounded, size: 24),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 2),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio'),
      onRemove: () => _removeTrack(context, provider, track),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: isAlreadyPlaying
            ? Color.alphaBlend(
                cs.primaryContainer.withValues(alpha: 0.40),
                cs.surfaceContainerHighest,
              )
            : cs.surfaceContainerHighest,
        child: SizedBox(
          height: 54,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    track.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      height: 1.06,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    Feedback.forTap(context);
                    unawaited(provider.spawnSession(track));
                    _showSessionCreatedSnack(
                      context,
                      i18n.tr('session_created', {'name': track.displayName}),
                    );
                  },
                  style: IconButton.styleFrom(
                    foregroundColor: cs.primary,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_rounded, size: 24),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryCoverThumbnail extends StatelessWidget {
  const _LibraryCoverThumbnail({
    required this.coverPathFuture,
    required this.title,
  });

  final Future<String?> coverPathFuture;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.secondaryContainer.withValues(alpha: 0.92),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 28,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 82,
      height: 66,
      child: Padding(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AsyncCoverImage(
            future: coverPathFuture,
            fallbackBuilder: (_) => fallback(),
            loadingBuilder: (_) => PulsingPlaceholder(
              borderRadius: BorderRadius.circular(12),
              child: fallback(),
            ),
            imageBuilder: (context, coverPath) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              return Image(
                image: resizeFileImageIfNeeded(
                  path: coverPath,
                  cacheWidth: (82 * dpr).round(),
                  cacheHeight: (66 * dpr).round(),
                ),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback(),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LibraryMetaChip extends StatelessWidget {
  const _LibraryMetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          icon,
          size: 12,
          color: cs.onSurfaceVariant.withValues(alpha: 0.65),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontStyle: FontStyle.italic,
              color: cs.onSurfaceVariant.withValues(alpha: 0.65),
              fontSize: 9,
            ),
          ),
        ),
      ],
    );
  }
}
