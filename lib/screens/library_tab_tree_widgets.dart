part of 'library_tab.dart';

class _LibraryTreeItem extends StatelessWidget {
  const _LibraryTreeItem({
    super.key,
    required this.node,
    this.initiallyExpanded = false,
    this.searchQuery = '',
  });

  final LibraryNode node;
  final bool initiallyExpanded;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    if (node is FolderNode) {
      return _FolderNodeWidget(
        folder: node as FolderNode,
        initiallyExpanded: initiallyExpanded,
        searchQuery: searchQuery,
      );
    } else if (node is TrackNode) {
      return _TrackNodeWidget(
        trackNode: node as TrackNode,
        searchQuery: searchQuery,
      );
    }
    return const SizedBox.shrink();
  }
}

class _FolderNodeWidget extends StatefulWidget {
  const _FolderNodeWidget({
    required this.folder,
    required this.initiallyExpanded,
    required this.searchQuery,
  });

  final FolderNode folder;
  final bool initiallyExpanded;
  final String searchQuery;

  @override
  State<_FolderNodeWidget> createState() => _FolderNodeWidgetState();
}

class _FolderNodeWidgetState extends State<_FolderNodeWidget> {
  static const double _rootFolderTileHeight = 82;
  static const double _childFolderTileHeight = 62;
  static const double _rootFolderTitleBlockHeight = 34;
  static const double _childFolderTitleBlockHeight = 50;

  final ExpansibleController _expansionController = ExpansibleController();
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _FolderNodeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.expand();
      });
    }
  }

  String? _findParentLibraryPath(AudioProvider provider) {
    for (final libraryPath in provider.watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(widget.folder.path, libraryPath)) {
        return libraryPath;
      }
    }
    return null;
  }

  Future<void> _removeFolder(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final libraryPath = _findParentLibraryPath(provider);
    if (libraryPath != null) {
      provider.setLibraryFolderExcluded(libraryPath, widget.folder.path, true);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('folder_excluded'),
          tone: AppFeedbackTone.warning,
          icon: Icons.block_rounded,
        );
      }
    } else {
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
    final hasChildren = widget.folder.children.isNotEmpty;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );
    final groupLabel = isRootFolder
        ? ''
        : _displaySourceName(path.dirname(widget.folder.path));

    Widget content = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        minTileHeight: isRootFolder
            ? _rootFolderTileHeight
            : _childFolderTileHeight,
        onExpansionChanged: (expanded) {
          if (_expanded == expanded) return;
          setState(() {
            _expanded = expanded;
          });
        },
        shape: isRootFolder
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))
            : const RoundedRectangleBorder(),
        collapsedShape: isRootFolder
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))
            : const RoundedRectangleBorder(),
        tilePadding: EdgeInsets.fromLTRB(isRootFolder ? 12 : 6, 2, 4, 2),
        childrenPadding: EdgeInsets.fromLTRB(isRootFolder ? 12 : 16, 0, 0, 0),
        title: Row(
          children: [
            if (isRootFolder) ...[
              _LibraryCoverThumbnail(
                folderPath: widget.folder.path,
                title: widget.folder.name,
              ),
              const SizedBox(width: 14),
            ] else ...[
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: cs.primary.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
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
                        if (groupLabel.isNotEmpty && isRootFolder) ...[
                          _HighlightedText(
                            text: groupLabel,
                            query: widget.searchQuery,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.65,
                                  ),
                                  fontWeight: FontWeight.w500,
                                  fontSize: 10,
                                ) ??
                                const TextStyle(),
                          ),
                          const SizedBox(height: 3),
                        ],
                        _HighlightedText(
                          text: widget.folder.name,
                          query: widget.searchQuery,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: isRootFolder
                                    ? FontWeight.w900
                                    : FontWeight.w700,
                                fontSize: isRootFolder ? 14 : 13,
                                height: 1.06,
                                color: isRootFolder
                                    ? cs.onSurface
                                    : cs.onSurface.withValues(alpha: 0.9),
                              ) ??
                              const TextStyle(),
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
                icon: const Icon(Icons.add_circle_rounded, size: 25),
              ),
              const SizedBox(width: 2),
              if (hasChildren)
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
        children: widget.folder.children
            .map(
              (childNode) => Padding(
                padding: EdgeInsets.only(top: isRootFolder ? 6 : 2),
                child: RepaintBoundary(
                  child: _LibraryTreeItem(
                    key: ValueKey(childNode.path),
                    node: childNode,
                    initiallyExpanded: widget.initiallyExpanded,
                    searchQuery: widget.searchQuery,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );

    if (!isRootFolder) {
      return content;
    }

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio_folder'),
      secondaryActionLabel: i18n.tr('audio_detail'),
      secondaryActionTooltip: i18n.tr('audio_detail'),
      onSecondaryAction: () => unawaited(
        showAudioDetailSheet(
          context,
          AudioDetailTarget.libraryRootFolder(widget.folder.path),
        ),
      ),
      onRemove: () => _removeFolder(context, provider),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: cs.surface,
        child: content,
      ),
    );
  }
}

class _TrackNodeWidget extends ConsumerWidget {
  const _TrackNodeWidget({required this.trackNode, this.searchQuery = ''});

  final TrackNode trackNode;
  final String searchQuery;

  Future<void> _removeTrack(
    BuildContext context,
    AudioProvider provider,
    MusicTrack track,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    String? parentLibraryPath;
    for (final libraryPath in provider.watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(track.path, libraryPath)) {
        parentLibraryPath = libraryPath;
        break;
      }
    }
    if (parentLibraryPath != null) {
      provider.setLibraryTrackExcluded(parentLibraryPath, track.path, true);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('audio_excluded'),
          tone: AppFeedbackTone.warning,
          icon: Icons.block_rounded,
        );
      }
    } else {
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
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
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
        secondaryActionLabel: i18n.tr('audio_detail'),
        secondaryActionTooltip: i18n.tr('audio_detail'),
        onSecondaryAction: () => unawaited(
          showAudioDetailSheet(
            context,
            AudioDetailTarget.singleAudioFile(track.path),
          ),
        ),
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
            height: 82,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _HighlightedText(
                          text: track.displayName,
                          query: searchQuery,
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
                      unawaited(provider.spawnSession(track, autoPlay: true));
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
                    icon: const Icon(Icons.add_circle_rounded, size: 25),
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
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              Icon(
                Icons.audio_file_rounded,
                size: 16,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HighlightedText(
                  text: track.displayName,
                  query: searchQuery,
                  maxLines: 1,
                  style:
                      Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: isAlreadyPlaying ? cs.primary : cs.onSurface,
                      ) ??
                      const TextStyle(),
                ),
              ),
              IconButton(
                onPressed: () {
                  Feedback.forTap(context);
                  unawaited(provider.spawnSession(track, autoPlay: true));
                  _showSessionCreatedSnack(
                    context,
                    i18n.tr('session_created', {'name': track.displayName}),
                  );
                },
                style: IconButton.styleFrom(
                  foregroundColor: cs.primary,
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
}

class _LibraryCoverThumbnail extends ConsumerWidget {
  const _LibraryCoverThumbnail({required this.folderPath, required this.title});

  final String folderPath;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    context.select<AudioProvider, int>((value) => value.coverGeneration);
    final provider = context.read<AudioProvider>();
    final coverPathFuture = provider.coverPathFutureForFolder(folderPath);
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

class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.style,
    this.maxLines = 2,
  });

  final String text;
  final String query;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }

      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }

      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: TextStyle(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.18),
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
      start = index + query.length;
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
