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

class _FolderNodeWidget extends ConsumerStatefulWidget {
  const _FolderNodeWidget({
    required this.folder,
    required this.initiallyExpanded,
    required this.searchQuery,
  });

  final FolderNode folder;
  final bool initiallyExpanded;
  final String searchQuery;

  @override
  ConsumerState<_FolderNodeWidget> createState() => _FolderNodeWidgetState();
}

class _FolderNodeWidgetState extends ConsumerState<_FolderNodeWidget> {
  static const double _rootFolderTileHeight =
      LibraryLikeCardMetrics.rootTileHeight;
  static const double _childFolderTileHeight = 44;
  static const double _childFolderTitleBlockHeight = 36;

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
    return provider.libraryRootForPath(widget.folder.path);
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
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    unawaited(provider.spawnSession(firstTrack));
    _showSessionCreatedSnack(
      context,
      i18n.tr('session_created', {'name': firstTrack.displayName}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
    ref.watch(libraryCategoryRevisionProvider);
    final categorySnapshot = provider.audioLibraryCategorySnapshotSync;
    final cs = Theme.of(context).colorScheme;
    final isRootFolder = widget.folder.depth == 0;
    final hasChildren = widget.folder.children.isNotEmpty;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.cardRadius),
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
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  LibraryLikeCardMetrics.cardRadius,
                ),
              )
            : const RoundedRectangleBorder(),
        collapsedShape: isRootFolder
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  LibraryLikeCardMetrics.cardRadius,
                ),
              )
            : const RoundedRectangleBorder(),
        showTrailingIcon: !isRootFolder,
        tilePadding: isRootFolder
            ? LibraryLikeCardMetrics.rootTilePadding
            : const EdgeInsets.fromLTRB(6, 2, 4, 2),
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
                padding: EdgeInsets.zero,
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
    final parentLibraryPath = provider.libraryRootForPath(track.path);
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
    ref.watch(libraryCategoryRevisionProvider);
    final categorySnapshot = provider.audioLibraryCategorySnapshotSync;
    final cs = Theme.of(context).colorScheme;
    final track = trackNode.track;
    final isAlreadyPlaying = ref
        .watch(activeTrackPathsProvider)
        .contains(track.path);
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
        verticalActions: track.isVideo,
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
          color: (isAlreadyPlaying && !track.isVideo)
              ? Color.alphaBlend(
                  cs.primaryContainer.withValues(alpha: 0.40),
                  cs.surface,
                )
              : cs.surface,
          child: track.isVideo
              ? ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                  minTileHeight: _FolderNodeWidgetState._rootFolderTileHeight,
                  title: _SingleVideoFileCardContent(
                    track: track,
                    title: track.displayName,
                    detail: singleDetail,
                    detailLoading: isSingleDetailLoading,
                    onPlay: () {
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.tap,
                        context: context,
                      );
                      unawaited(provider.spawnSession(track, autoPlay: true));
                      _showSessionCreatedSnack(
                        context,
                        i18n.tr('session_created', {'name': track.displayName}),
                      );
                    },
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
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
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.tap,
                            context: context,
                          );
                          unawaited(provider.spawnSession(track));
                          _showSessionCreatedSnack(
                            context,
                            i18n.tr('session_created', {
                              'name': track.displayName,
                            }),
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
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio'),
      onRemove: () => _removeTrack(context, provider, track),
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
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.tap,
                    context: context,
                  );
                  unawaited(provider.spawnSession(track));
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

class _LibraryCoverThumbnail extends ConsumerStatefulWidget {
  const _LibraryCoverThumbnail({required this.folderPath, this.width = 82});

  final String folderPath;
  final double width;

  @override
  ConsumerState<_LibraryCoverThumbnail> createState() =>
      _LibraryCoverThumbnailState();
}

class _LibraryCoverThumbnailState
    extends ConsumerState<_LibraryCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastFolderPath;
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(AudioProvider provider, int coverGeneration) {
    if (_lastFolderPath != widget.folderPath ||
        _lastCoverGeneration != coverGeneration) {
      _lastFolderPath = widget.folderPath;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = provider.coverPathFutureForFolder(widget.folderPath);
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final coverPathFuture = _coverFutureFor(provider, coverGeneration);
    Widget fallback({bool hideIcon = false}) {
      return CoverFallbackArtwork(
        seed: widget.folderPath,
        showIcon: !hideIcon,
        compact: true,
        iconSize: 28,
      );
    }

    final width = widget.width;
    final height = width * 0.8;
    return SizedBox(
      width: width,
      height: height,
      child: Padding(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            LibraryLikeCardMetrics.coverRadius,
          ),
          child: Hero(
            tag: 'cover_${widget.folderPath}',
            placeholderBuilder: (context, heroSize, child) => child,
            child: AsyncCoverImage(
              future: coverPathFuture,
              initialPath: provider.resolvedCoverPathForFolder(
                widget.folderPath,
              ),
              retryFutureBuilder: () =>
                  provider.coverPathFutureForFolder(widget.folderPath),
              duration: Duration.zero,
              fallbackBuilder: (_) => fallback(),
              loadingBuilder: (_) => CoverLoadingArtwork(
                placeholder: fallback(hideIcon: true),
                size: 34,
                strokeWidth: 3,
                color: Theme.of(context).colorScheme.primary,
              ),
              imageBuilder: (context, coverPath) {
                return RetryingFileImage(
                  path: coverPath,
                  cacheWidth: coverCacheWidthForDisplay(context, width),
                  fit: BoxFit.cover,
                  fallbackBuilder: (_) => fallback(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryTrackCoverThumbnail extends ConsumerStatefulWidget {
  const _LibraryTrackCoverThumbnail({required this.track, this.width = 82});

  final MusicTrack track;
  final double width;

  @override
  ConsumerState<_LibraryTrackCoverThumbnail> createState() =>
      _LibraryTrackCoverThumbnailState();
}

class _LibraryTrackCoverThumbnailState
    extends ConsumerState<_LibraryTrackCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(AudioProvider provider, int coverGeneration) {
    if (_lastTrackPath != widget.track.path ||
        _lastCoverGeneration != coverGeneration) {
      _lastTrackPath = widget.track.path;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = provider.coverPathFutureForTrack(widget.track);
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final coverPathFuture = _coverFutureFor(provider, coverGeneration);
    final track = widget.track;

    Widget fallback({bool hideIcon = false}) {
      return CoverFallbackArtwork(
        seed: track.displayName,
        showIcon: !hideIcon,
        compact: true,
        iconSize: 28,
      );
    }

    final width = widget.width;
    final height = width * 0.8;
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
        child: Hero(
          tag: 'cover_${track.path}',
          placeholderBuilder: (context, heroSize, child) => child,
          child: AsyncCoverImage(
            future: coverPathFuture,
            initialPath: provider.resolvedCoverPathForTrack(track),
            retryFutureBuilder: () => provider.coverPathFutureForTrack(track),
            duration: Duration.zero,
            fallbackBuilder: (_) => fallback(),
            loadingBuilder: (_) => CoverLoadingArtwork(
              placeholder: fallback(hideIcon: true),
              size: 34,
              strokeWidth: 3,
              color: Theme.of(context).colorScheme.primary,
            ),
            imageBuilder: (context, coverPath) {
              return RetryingFileImage(
                path: coverPath,
                cacheWidth: coverCacheWidthForDisplay(context, width),
                fit: BoxFit.cover,
                fallbackBuilder: (_) => fallback(),
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
    return _LibraryFeaturedCardContent(
      title: folderName,
      detail: detail,
      detailLoading: detailLoading,
      expanded: expanded,
      showExpandIndicator: hasChildren,
      onPlay: onPlay,
      coverBuilder: (coverWidth) =>
          _LibraryCoverThumbnail(folderPath: folderPath, width: coverWidth),
    );
  }
}

class _LibraryFeaturedCardContent extends StatelessWidget {
  const _LibraryFeaturedCardContent({
    required this.title,
    required this.detail,
    required this.detailLoading,
    required this.coverBuilder,
    required this.onPlay,
    this.expanded = false,
    this.showExpandIndicator = false,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final fields = context.select<AudioProvider, List<CardInfoField>>(
      (provider) => provider.cardInfoFields,
    );
    return LibraryLikeFeaturedCardContent(
      title: title,
      lines: _audioDetailInfoLines(i18n, detail, detailLoading, fields),
      coverBuilder: coverBuilder,
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: showExpandIndicator,
      playTooltip: i18n.tr('play'),
      enableMarquee: false,
      enableTitleMarquee: false,
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
    final i18n = context.watch<AppLanguageProvider>();
    final fields = context.select<AudioProvider, List<CardInfoField>>(
      (provider) => provider.cardInfoFields,
    );
    return LibraryLikeSingleAudioCardContent(
      title: title,
      lines: _audioDetailInfoLines(i18n, detail, detailLoading, fields),
      enableMarquee: false,
      enableTitleMarquee: false,
    );
  }
}

class _SingleVideoFileCardContent extends StatelessWidget {
  const _SingleVideoFileCardContent({
    required this.track,
    required this.title,
    required this.detail,
    required this.detailLoading,
    required this.onPlay,
  });

  final MusicTrack track;
  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return _LibraryFeaturedCardContent(
      title: title,
      detail: detail,
      detailLoading: detailLoading,
      onPlay: onPlay,
      coverBuilder: (coverWidth) =>
          _LibraryTrackCoverThumbnail(track: track, width: coverWidth),
    );
  }
}

class _AudioDetailInfoLineData extends LibraryLikeInfoLineData {
  const _AudioDetailInfoLineData(super.label, super.text, {super.lines = 1});
}

List<_AudioDetailInfoLineData> _audioDetailInfoLines(
  AppLanguageProvider i18n,
  AudioDetail? detail,
  bool detailLoading,
  List<CardInfoField> fields,
) {
  final d = detail;
  if (detailLoading || d == null) {
    return const <_AudioDetailInfoLineData>[];
  }

  final result = <_AudioDetailInfoLineData>[];
  for (final field in fields) {
    switch (field) {
      case CardInfoField.rjCode:
        if (d.rjCode.trim().isNotEmpty) {
          result.add(_AudioDetailInfoLineData('RJ', d.rjCode.trim()));
        }
        break;
      case CardInfoField.voiceActors:
        if (d.voiceActors.isNotEmpty) {
          result.add(
            _AudioDetailInfoLineData(
              'CV',
              AudioDetail.normalizeList(d.voiceActors).join('\uFF0C'),
            ),
          );
        }
        break;
      case CardInfoField.circleName:
        if (d.circleName.trim().isNotEmpty) {
          result.add(
            _AudioDetailInfoLineData(
              i18n.tr('library_category_circles'),
              d.circleName.trim(),
            ),
          );
        }
        break;
      case CardInfoField.tags:
        if (d.tags.isNotEmpty) {
          result.add(_tagsDetailInfoLine(i18n, d.tags, fields.length));
        }
        break;
      case CardInfoField.releaseDate:
        final value = _formatLibraryCardDate(d.releaseDate);
        if (value.isNotEmpty) {
          result.add(
            _AudioDetailInfoLineData(i18n.tr('card_info_release_date'), value),
          );
        }
        break;
      case CardInfoField.salesCount:
        final value = d.salesCount;
        if (value != null && value > 0) {
          result.add(
            _AudioDetailInfoLineData(
              i18n.tr('card_info_sales_count'),
              value.toString(),
            ),
          );
        }
        break;
      case CardInfoField.rating:
        final value = _formatLibraryCardRating(d.rating);
        if (value.isNotEmpty) {
          result.add(
            _AudioDetailInfoLineData(i18n.tr('card_info_rating'), value),
          );
        }
        break;
    }
  }
  return result;
}

_AudioDetailInfoLineData _tagsDetailInfoLine(
  AppLanguageProvider i18n,
  List<String> tags,
  int selectedFieldCount,
) {
  final text = AudioDetail.normalizeList(tags).join('\uFF0C');
  return _AudioDetailInfoLineData(
    i18n.tr('library_category_tags'),
    text,
    lines: CardInfoField.tagLineCountForSelection(selectedFieldCount),
  );
}

String _formatLibraryCardDate(DateTime? value) {
  if (value == null) return '';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String _formatLibraryCardRating(double? value) {
  if (value == null || value <= 0) return '';
  return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1);
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
