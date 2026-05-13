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
  static const double _rootFolderTileHeight = 160;
  static const double _childFolderTileHeight = 62;
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
    final categorySnapshot = context
        .select<AudioProvider, AudioLibraryCategorySnapshot?>(
          (value) => value.audioLibraryCategorySnapshotSync,
        );
    final cs = Theme.of(context).colorScheme;
    final isRootFolder = widget.folder.depth == 0;
    final hasChildren = widget.folder.children.isNotEmpty;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );
    final rootDetail = isRootFolder
        ? categorySnapshot?.detailFor(
            AudioDetailTarget.libraryRootFolder(widget.folder.path),
          )
        : null;
    final isRootDetailLoading = isRootFolder && categorySnapshot == null;

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
        showTrailingIcon: !isRootFolder,
        tilePadding: EdgeInsets.fromLTRB(
          isRootFolder ? 12 : 6,
          2,
          isRootFolder ? 12 : 4,
          2,
        ),
        childrenPadding: EdgeInsets.fromLTRB(isRootFolder ? 12 : 16, 0, 0, 0),
        title: isRootFolder
            ? _RootFolderCardContent(
                folderPath: widget.folder.path,
                folderName: widget.folder.name,
                detail: rootDetail,
                detailLoading: isRootDetailLoading,
                expanded: _expanded,
                hasChildren: hasChildren,
                onPlay: () => _playFolder(context, provider),
              )
            : Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.folder_open_rounded
                        : Icons.folder_rounded,
                    size: 20,
                    color: cs.primary.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: _childFolderTitleBlockHeight,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HighlightedText(
                            text: widget.folder.name,
                            query: widget.searchQuery,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  height: 1.06,
                                  color: cs.onSurface.withValues(alpha: 0.9),
                                ) ??
                                const TextStyle(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
        trailing: isRootFolder
            ? null
            : SizedBox(
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
      verticalActions: true,
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
    final categorySnapshot = context
        .select<AudioProvider, AudioLibraryCategorySnapshot?>(
          (value) => value.audioLibraryCategorySnapshotSync,
        );
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
    final singleDetail = track.isSingle
        ? categorySnapshot?.detailFor(
            AudioDetailTarget.singleAudioFile(track.path),
          )
        : null;
    final isSingleDetailLoading = track.isSingle && categorySnapshot == null;

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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                Expanded(
                  child: _SingleAudioFileCardContent(
                    title: track.displayName,
                    detail: singleDetail,
                    detailLoading: isSingleDetailLoading,
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
  const _LibraryCoverThumbnail({
    required this.folderPath,
    required this.title,
    this.width = 82,
  });

  final String folderPath;
  final String title;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    context.select<AudioProvider, int>((value) => value.coverGeneration);
    final provider = context.read<AudioProvider>();
    final coverPathFuture = provider.coverPathFutureForFolder(folderPath);
    final isCoverLoading = provider.isCoverPathLoadingForFolder(folderPath);
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

    final height = width * 0.8;
    return SizedBox(
      width: width,
      height: height,
      child: Padding(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AsyncCoverImage(
            future: coverPathFuture,
            fallbackBuilder: (_) => fallback(),
            loadingBuilder: (_) => Stack(
              fit: StackFit.expand,
              children: [
                fallback(),
                if (isCoverLoading)
                  Center(
                    child: Icon(
                      Icons.hourglass_top_rounded,
                      size: 22,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
              ],
            ),
            imageBuilder: (context, coverPath) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              return Image(
                image: resizeFileImageIfNeeded(
                  path: coverPath,
                  cacheWidth: (width * dpr).round(),
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

class _RootFolderCardContent extends StatelessWidget {
  const _RootFolderCardContent({
    required this.folderPath,
    required this.folderName,
    required this.detail,
    required this.detailLoading,
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
  });

  final String folderPath;
  final String folderName;
  final AudioDetail? detail;
  final bool detailLoading;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
          fontSize: 14,
          height: 1.06,
          color: cs.onSurface,
        ) ??
        const TextStyle();
    final infoStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        );
    final emptyText = i18n.tr('audio_detail_empty');

    return LayoutBuilder(
      builder: (context, constraints) {
        const infoBlockHeight = 96.0;
        const titleBlockHeight = 38.0;
        const coverWidth = infoBlockHeight * 1.25;
        return SizedBox(
          height: 140,
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LibraryCoverThumbnail(
                    folderPath: folderPath,
                    title: folderName,
                    width: coverWidth,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: infoBlockHeight,
                      child: Column(
                        children: [
                          _LibraryDetailInfoLine(
                            label: 'RJ',
                            text: _nonEmpty(detail?.rjCode, emptyText),
                            style: infoStyle,
                            loading: detailLoading,
                          ),
                          const SizedBox(height: 4),
                          _LibraryDetailInfoLine(
                            label: 'CV',
                            text: _joinedOrEmpty(
                              detail?.voiceActors,
                              emptyText,
                            ),
                            style: infoStyle,
                            loading: detailLoading,
                          ),
                          const SizedBox(height: 4),
                          _LibraryDetailInfoLine(
                            label: '社团',
                            text: _nonEmpty(detail?.circleName, emptyText),
                            style: infoStyle,
                            loading: detailLoading,
                          ),
                          const SizedBox(height: 4),
                          _LibraryDetailInfoLine(
                            label: '标签',
                            text: _joinedOrEmpty(detail?.tags, emptyText),
                            style: infoStyle,
                            loading: detailLoading,
                            lines: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: titleBlockHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: _LibraryTwoLineMarqueeText(
                        text: folderName,
                        style: titleStyle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: onPlay,
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
                    if (hasChildren)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: IgnorePointer(
                          child: AnimatedRotation(
                            turns: expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              Icons.expand_more_rounded,
                              color: cs.onSurfaceVariant,
                              size: 21,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SingleAudioFileCardContent extends StatelessWidget {
  const _SingleAudioFileCardContent({
    required this.title,
    required this.detail,
    required this.detailLoading,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;

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
    final infoStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        );
    final d = detail;
    final lines = detailLoading || d == null
        ? const <_AudioDetailInfoLineData>[]
        : [
            if (d.rjCode.trim().isNotEmpty)
              _AudioDetailInfoLineData('RJ', d.rjCode.trim()),
            if (d.voiceActors.isNotEmpty)
              _AudioDetailInfoLineData(
                'CV',
                AudioDetail.normalizeList(d.voiceActors).join('\uFF0C'),
              ),
            if (d.circleName.trim().isNotEmpty)
              _AudioDetailInfoLineData('\u793e\u56e2', d.circleName.trim()),
            if (d.tags.isNotEmpty)
              _AudioDetailInfoLineData(
                '\u6807\u7b7e',
                AudioDetail.normalizeList(d.tags).join('\uFF0C'),
              ),
          ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LibraryTwoLineMarqueeText(text: title, style: titleStyle),
        for (final line in lines) ...[
          const SizedBox(height: 3),
          _LibraryDetailInfoLine(
            label: line.label,
            text: line.text,
            style: infoStyle,
            loading: false,
          ),
        ],
      ],
    );
  }
}

class _AudioDetailInfoLineData {
  const _AudioDetailInfoLineData(this.label, this.text);

  final String label;
  final String text;
}

class _LibraryDetailInfoLine extends StatelessWidget {
  const _LibraryDetailInfoLine({
    required this.label,
    required this.text,
    required this.style,
    required this.loading,
    this.lines = 1,
  });

  final String label;
  final String text;
  final TextStyle style;
  final bool loading;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lineCount = lines.clamp(1, 2);
    return SizedBox(
      height: lineCount == 2 ? 36 : 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: style.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: loading
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      Icons.hourglass_top_rounded,
                      size: 12,
                      color: cs.primary,
                    ),
                  )
                : lineCount == 2
                ? _LibraryTwoLineMarqueeText(text: text, style: style)
                : MarqueeText(text: text, style: style, scrollSpeed: 24),
          ),
        ],
      ),
    );
  }
}

String _nonEmpty(String? value, String fallback) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _joinedOrEmpty(Iterable<String>? values, String fallback) {
  final text = AudioDetail.normalizeList(values ?? const <String>[]).join('，');
  return text.isEmpty ? fallback : text;
}

class _LibrarySecondaryInfoLine extends StatelessWidget {
  const _LibrarySecondaryInfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: cs.primary,
          fontSize: 10,
          height: 1.05,
        ) ??
        TextStyle(
          fontWeight: FontWeight.w800,
          color: cs.primary,
          fontSize: 10,
          height: 1.05,
        );
    return SizedBox(
      width: double.infinity,
      height: 14,
      child: Row(
        children: [
          Icon(icon, size: 12, color: cs.primary),
          const SizedBox(width: 5),
          Expanded(
            child: MarqueeText(text: text, style: style),
          ),
        ],
      ),
    );
  }
}

class _LibraryTertiaryInfoLine extends StatelessWidget {
  const _LibraryTertiaryInfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 14,
      child: Row(
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
                height: 1.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryMarqueeLine extends StatelessWidget {
  const _LibraryMarqueeLine({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 16,
      child: MarqueeText(text: text, style: style, scrollSpeed: 26),
    );
  }
}

class _LibraryTwoLineMarqueeText extends StatelessWidget {
  const _LibraryTwoLineMarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final lines = _splitLibraryName(text);
    return SizedBox(
      width: double.infinity,
      height: 34,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LibraryMarqueeLine(text: lines.$1, style: style),
          const SizedBox(height: 2),
          _LibraryMarqueeLine(text: lines.$2, style: style),
        ],
      ),
    );
  }
}

(String, String) _splitLibraryName(String value) {
  final text = value.trim();
  if (text.length <= 18) return (text, '');

  final middle = text.length ~/ 2;
  var splitIndex = middle;
  var bestDistance = text.length;
  for (var i = 1; i < text.length - 1; i++) {
    final char = text[i];
    if (!RegExp(r'[\s_\-\.・、，,（）()\[\]【】]+').hasMatch(char)) {
      continue;
    }
    final distance = (i - middle).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      splitIndex = i + 1;
    }
  }

  final first = text.substring(0, splitIndex).trim();
  final second = text.substring(splitIndex).trim();
  if (first.isEmpty || second.isEmpty) return (text, '');
  return (first, second);
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
