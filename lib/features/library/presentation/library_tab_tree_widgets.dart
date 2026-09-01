part of 'library_tab.dart';

class _LibrarySelectionIndicator extends StatelessWidget {
  const _LibrarySelectionIndicator();

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0xFF4CAF50),
      border: Border.all(color: Colors.white, width: 1.5),
    ),
    child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
  );
}

class _LibraryTreeItem extends StatelessWidget {
  const _LibraryTreeItem({
    super.key,
    required this.node,
    this.initiallyExpanded = false,
    this.searchQuery = '',
    this.index,
    this.onFolderExpansionChanged,
    this.renderChildrenInline = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final LibraryNode node;
  final bool initiallyExpanded;
  final String searchQuery;
  final int? index;
  final void Function(FolderNode folder, bool expanded)?
  onFolderExpansionChanged;
  final bool renderChildrenInline;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    if (node is FolderNode) {
      return _FolderNodeWidget(
        folder: node as FolderNode,
        initiallyExpanded: initiallyExpanded,
        onFolderExpansionChanged: onFolderExpansionChanged,
        renderChildrenInline: renderChildrenInline,
        searchQuery: searchQuery,
        index: index,
        isSelectionMode: isSelectionMode,
        isSelected: isSelected,
        onLongPress: onLongPress,
        onToggleSelect: onToggleSelect,
      );
    } else if (node is TrackNode) {
      return _TrackNodeWidget(
        trackNode: node as TrackNode,
        searchQuery: searchQuery,
        index: index,
        isSelectionMode: isSelectionMode,
        isSelected: isSelected,
        onLongPress: onLongPress,
        onToggleSelect: onToggleSelect,
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
    this.index,
    this.onFolderExpansionChanged,
    this.renderChildrenInline = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final FolderNode folder;
  final bool initiallyExpanded;
  final String searchQuery;
  final int? index;
  final void Function(FolderNode folder, bool expanded)?
  onFolderExpansionChanged;
  final bool renderChildrenInline;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

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
  FolderNode? _loadedFolder;
  bool _isLoadingChildren = false;
  bool _hasLoadError = false;
  bool _hasResolvedCover = false;

  @override
  void initState() {
    super.initState();
    _hasResolvedCover = _hasCachedCoverFor(widget.folder.path);
    if (widget.renderChildrenInline &&
        widget.initiallyExpanded &&
        widget.folder.children.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadChildren());
      });
    }
  }

  @override
  void didUpdateWidget(covariant _FolderNodeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.folder, widget.folder)) {
      if (!PathMatcher.equalsNormalized(
        oldWidget.folder.path,
        widget.folder.path,
      )) {
        _hasResolvedCover = _hasCachedCoverFor(widget.folder.path);
      }
      final retainLoadedChildren =
          _loadedFolder != null &&
          widget.folder.children.isEmpty &&
          PathMatcher.equalsNormalized(
            oldWidget.folder.path,
            widget.folder.path,
          );
      if (!retainLoadedChildren) {
        _loadedFolder = null;
      }
      _isLoadingChildren = false;
      _hasLoadError = false;
      if (widget.renderChildrenInline &&
          _expanded &&
          widget.folder.children.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_loadChildren(refresh: retainLoadedChildren));
          }
        });
      }
    }
    if (widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _expansionController.expand();
        if (widget.renderChildrenInline) unawaited(_loadChildren());
      });
      return;
    }
    if (!widget.initiallyExpanded && oldWidget.initiallyExpanded && _expanded) {
      _expanded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.collapse();
      });
    }
  }

  bool _hasCachedCoverFor(String folderPath) =>
      ref
          .read(libraryFacadeProvider)
          .resolvedCoverPathForFolder(folderPath)
          ?.trim()
          .isNotEmpty ==
      true;

  Future<void> _loadChildren({bool refresh = false}) async {
    if ((!refresh && _loadedFolder != null) ||
        _isLoadingChildren ||
        widget.folder.children.isNotEmpty) {
      return;
    }
    final requestedCard = widget.folder;
    final requestedPath = widget.folder.path;
    final keepCurrentChildrenVisible = _loadedFolder != null;
    if (keepCurrentChildrenVisible) {
      _isLoadingChildren = true;
    } else {
      setState(() {
        _isLoadingChildren = true;
        _hasLoadError = false;
      });
    }
    try {
      final folder = await ref
          .read(libraryFacadeProvider)
          .loadLibraryFolderTree(requestedPath);
      if (!mounted ||
          !identical(widget.folder, requestedCard) ||
          !PathMatcher.equalsNormalized(widget.folder.path, requestedPath)) {
        return;
      }
      setState(() {
        _loadedFolder = folder;
        _hasLoadError = folder == null;
        _isLoadingChildren = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasLoadError = true;
          _isLoadingChildren = false;
        });
      }
    } finally {
      if (mounted && _isLoadingChildren) {
        setState(() => _isLoadingChildren = false);
      } else {
        _isLoadingChildren = false;
      }
    }
  }

  Future<void> _removeFolder(BuildContext context) async {
    await _stageLibraryRemoval(
      context,
      ref,
      targetPath: widget.folder.path,
      target: _LibraryRemovalTarget.folder,
    );
  }

  Future<void> _playFolder(
    BuildContext context,
    PlaybackFacade playback,
  ) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final firstTrack = widget.folder.firstTrack;
    if (firstTrack == null) return;
    unawaited(
      AppInteractionFeedback.trigger(
        AppInteractionFeedbackType.tap,
        context: context,
      ),
    );
    final created = await playback.spawnSession(firstTrack);
    if (!context.mounted) return;
    if (created) {
      _showSessionCreatedSnack(
        context,
        i18n.tr('session_created', {'name': firstTrack.displayName}),
      );
    } else {
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(
      isUndoableRemovalHiddenProvider(_libraryRemovalKey(widget.folder.path)),
    )) {
      return const SizedBox.shrink();
    }
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final playback = ref.read(playbackFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final folder = _loadedFolder ?? widget.folder;
    final isRootFolder = folder.depth == 0;
    final rootDetailState = isRootFolder
        ? ref.watch(
            libraryDetailForTargetProvider(
              AudioDetailTarget.libraryRootFolder(folder.path),
            ),
          )
        : null;
    final hasChildren =
        folder.children.isNotEmpty || folder.totalTrackCount > 0;
    const cardShape = LibraryLikeCardMetrics.cardShape;
    final rootDetail = rootDetailState?.value;
    final isRootDetailLoading = rootDetailState?.isLoading ?? false;
    final rootCardInfoFields = isRootFolder
        ? ref.watch(
            settingsStateProvider.select(
              (state) => state.value?.cardInfoFields ?? CardInfoField.defaults,
            ),
          )
        : const <CardInfoField>[];
    final useCompactRootCard =
        isRootFolder && rootCardInfoFields.isEmpty && _hasResolvedCover;

    Widget content = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        expansionAnimationStyle: appExpansionAnimationStyle(context),
        key: PageStorageKey<String>('library-folder:${folder.path}'),
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        minTileHeight: isRootFolder
            ? (useCompactRootCard
                  ? LibraryLikeCardMetrics.compactRootTileHeight
                  : _rootFolderTileHeight)
            : _childFolderTileHeight,
        enabled: !widget.isSelectionMode,
        onExpansionChanged: (expanded) {
          if (_expanded == expanded) return;
          setState(() {
            _expanded = expanded;
          });
          widget.onFolderExpansionChanged?.call(widget.folder, expanded);
          if (expanded && widget.renderChildrenInline) {
            unawaited(_loadChildren());
          }
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
        childrenPadding: EdgeInsets.fromLTRB(isRootFolder ? 8 : 4, 0, 0, 0),
        title: isRootFolder
            ? _RootFolderCardContent(
                folderPath: folder.path,
                folderName: folder.name,
                folderDuration: folder.totalDuration,
                detail: rootDetail,
                detailLoading: isRootDetailLoading,
                expanded: _expanded,
                hasChildren: hasChildren,
                onPlay: () => unawaited(_playFolder(context, playback)),
                index: widget.index,
                isSelected: widget.isSelected,
                hasResolvedCover: _hasResolvedCover,
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
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SizedBox(
                      height: _childFolderTitleBlockHeight,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SearchHighlightedText(
                            text: folder.name,
                            terms: extractSearchTerms(widget.searchQuery),
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
                      onPressed: () =>
                          unawaited(_playFolder(context, playback)),
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
        children: !_expanded || !widget.renderChildrenInline
            ? const <Widget>[]
            : <Widget>[
                if (_isLoadingChildren)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_hasLoadError)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: OperationStatusBanner(
                      key: ValueKey<String>(
                        'folder_children_error:${folder.path}',
                      ),
                      label: i18n.tr('operation_failed_retry'),
                      onRetry: () => unawaited(_loadChildren(refresh: true)),
                      retryTooltip: i18n.tr('retry'),
                    ),
                  )
                else
                  ...folder.children.map(
                    (childNode) => Padding(
                      padding: EdgeInsets.zero,
                      child: RepaintBoundary(
                        child: _LibraryTreeItem(
                          key: ValueKey(childNode.path),
                          node: childNode,
                          initiallyExpanded:
                              widget.onFolderExpansionChanged == null
                              ? widget.initiallyExpanded
                              : false,
                          onFolderExpansionChanged:
                              widget.onFolderExpansionChanged,
                          searchQuery: widget.searchQuery,
                        ),
                      ),
                    ),
                  ),
              ],
      ),
    );

    if (!isRootFolder) {
      return content;
    }

    return GestureDetector(
      onLongPress: widget.onLongPress,
      onTap: widget.isSelectionMode ? widget.onToggleSelect : null,
      child: SwipeRevealCard(
        shape: cardShape,
        enabled: !widget.isSelectionMode,
        closedColor: cs.surface,
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
        onRemove: () => _removeFolder(context),
        onWillReveal: _expansionController.collapse,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          color: widget.isSelected
              ? cs.primaryContainer.withValues(alpha: 0.25)
              : Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          child: content,
        ),
      ),
    );
  }
}

class _TrackNodeWidget extends ConsumerWidget {
  const _TrackNodeWidget({
    required this.trackNode,
    this.searchQuery = '',
    this.index,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final TrackNode trackNode;
  final String searchQuery;
  final int? index;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  Future<void> _removeTrack(
    BuildContext context,
    WidgetRef ref,
    MusicTrack track,
  ) async {
    await _stageLibraryRemoval(
      context,
      ref,
      targetPath: track.path,
      target: _LibraryRemovalTarget.track,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(
      isUndoableRemovalHiddenProvider(_libraryRemovalKey(trackNode.track.path)),
    )) {
      return const SizedBox.shrink();
    }
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final playback = ref.read(playbackFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final track = trackNode.track;
    final singleDetailState = track.isSingle
        ? ref.watch(
            libraryDetailForTargetProvider(
              AudioDetailTarget.singleAudioFile(track.path),
            ),
          )
        : null;
    final visibleCoverPath = track.isSingle && !track.isVideo
        ? ref.watch(libraryCoverForTrackProvider(track.path)).value
        : null;
    final isAlreadyPlaying = ref.watch(isTrackActiveProvider(track.path));
    const cardShape = LibraryLikeCardMetrics.cardShape;
    final singleDetail = singleDetailState?.value;
    final isSingleDetailLoading = singleDetailState?.isLoading ?? false;
    final resolvedCoverPath =
        visibleCoverPath ?? library.resolvedCoverPathForTrack(track);
    final useFeaturedSingleCard =
        track.isVideo || hasDisplayableCoverArtwork(track, resolvedCoverPath);

    Future<void> playSingleTrack() async {
      unawaited(
        AppInteractionFeedback.trigger(
          AppInteractionFeedbackType.tap,
          context: context,
        ),
      );
      final created = await playback.spawnSession(
        track,
        autoPlay: track.isVideo ? true : null,
      );
      if (!context.mounted) return;
      if (created) {
        _showSessionCreatedSnack(
          context,
          i18n.tr('session_created', {'name': track.displayName}),
        );
      } else {
        showAppSnackBar(
          context,
          i18n.tr('operation_failed_retry'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
      }
    }

    Widget buildSingleTrackCard(bool useFeaturedCard) {
      return GestureDetector(
        onLongPress: onLongPress,
        onTap: isSelectionMode ? onToggleSelect : null,
        child: SwipeRevealCard(
          shape: cardShape,
          enabled: !isSelectionMode,
          closedColor: cs.surface,
          actionLabel: i18n.tr('remove'),
          removeTooltip: i18n.tr('remove_audio'),
          secondaryActionLabel: i18n.tr('audio_detail'),
          secondaryActionTooltip: i18n.tr('audio_detail'),
          verticalActions: useFeaturedCard,
          onSecondaryAction: () => unawaited(
            showAudioDetailSheet(
              context,
              AudioDetailTarget.singleAudioFile(track.path),
            ),
          ),
          onRemove: () => _removeTrack(context, ref, track),
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: cardShape,
            color: isSelected
                ? cs.primaryContainer.withValues(alpha: 0.25)
                : (isAlreadyPlaying && !track.isVideo)
                ? Color.alphaBlend(
                    cs.primaryContainer.withValues(alpha: 0.40),
                    cs.surface,
                  )
                : Colors.transparent,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            child: useFeaturedCard
                ? ListTile(
                    contentPadding: LibraryLikeCardMetrics.rootTilePadding,
                    minTileHeight: _FolderNodeWidgetState._rootFolderTileHeight,
                    title: _SingleMediaFileCardContent(
                      track: track,
                      title: track.displayName,
                      detail: singleDetail,
                      detailLoading: isSingleDetailLoading,
                      index: index,
                      isSelected: isSelected,
                      onPlay: () => unawaited(playSingleTrack()),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
                    child: Row(
                      children: [
                        if (isSelected) ...[
                          const _LibrarySelectionIndicator(),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        Expanded(
                          child: _SingleAudioFileCardContent(
                            title: track.displayName,
                            detail: singleDetail,
                            detailLoading: isSingleDetailLoading,
                          ),
                        ),
                        IconButton(
                          onPressed: () => unawaited(playSingleTrack()),
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

    if (track.isSingle) {
      return buildSingleTrackCard(useFeaturedSingleCard);
    }

    return SwipeRevealCard(
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio'),
      onRemove: () => _removeTrack(context, ref, track),
      child: ColoredBox(
        color: Colors.transparent,
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Row(
              children: [
                Icon(
                  Icons.audio_file_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: SearchHighlightedText(
                    text: track.displayName,
                    terms: extractSearchTerms(searchQuery),
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
                  onPressed: () async {
                    unawaited(
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.tap,
                        context: context,
                      ),
                    );
                    final created = await playback.spawnSession(track);
                    if (!context.mounted) return;
                    if (created) {
                      _showSessionCreatedSnack(
                        context,
                        i18n.tr('session_created', {'name': track.displayName}),
                      );
                    } else {
                      showAppSnackBar(
                        context,
                        i18n.tr('operation_failed_retry'),
                        tone: AppFeedbackTone.destructive,
                        icon: Icons.error_outline_rounded,
                      );
                    }
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
      ),
    );
  }
}

class _LibraryCoverThumbnail extends ConsumerStatefulWidget {
  const _LibraryCoverThumbnail({
    required this.folderPath,
    this.width = 82,
    this.duration,
  });

  final String folderPath;
  final double width;
  final Duration? duration;

  @override
  ConsumerState<_LibraryCoverThumbnail> createState() =>
      _LibraryCoverThumbnailState();
}

class _LibraryCoverThumbnailState
    extends ConsumerState<_LibraryCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastFolderPath;
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    int coverGeneration,
  ) {
    if (_lastFolderPath != widget.folderPath ||
        _lastCoverGeneration != coverGeneration) {
      _lastFolderPath = widget.folderPath;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = _deferLibraryCardCoverLookup(
        isMounted: () => mounted,
        lookup: () => coverUi.deferredFolderCover(widget.folderPath),
      );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final resolution = ref.watch(
      settingsStateProvider.select(
        (s) => s.value?.coverImageResolution ?? CoverImageResolution.balanced,
      ),
    );
    final libraryFacade = ref.read(libraryFacadeProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverGeneration);
    final width = widget.width;
    final height = width / kStandardCoverAspectRatio;
    final coverCacheWidth = coverCacheWidthForLogicalSize(
      logicalWidth: width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: resolution,
    );
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                LibraryLikeCardMetrics.coverRadius,
              ),
              child: Hero(
                tag: 'cover_${widget.folderPath}',
                placeholderBuilder: (context, heroSize, child) => child,
                child: AsyncLocalCoverImage(
                  future: coverPathFuture,
                  requestKey: widget.folderPath,
                  initialPath: libraryFacade.resolvedCoverPathForFolder(
                    widget.folderPath,
                  ),
                  retryFutureBuilder: () =>
                      coverUi.deferredFolderCover(widget.folderPath),
                  seed: widget.folderPath,
                  cacheWidth: coverCacheWidth,
                  useDefaultCacheWidth: false,
                  fit: BoxFit.cover,
                  compact: true,
                  iconSize: 28,
                ),
              ),
            ),
          ),
          if (widget.duration != null && widget.duration! > Duration.zero)
            Positioned(
              right: 4,
              bottom: 4,
              child: DurationOverlay(duration: widget.duration!),
            ),
        ],
      ),
    );
  }
}

class _LibraryTrackCoverThumbnail extends ConsumerStatefulWidget {
  const _LibraryTrackCoverThumbnail({
    required this.track,
    this.width = 82,
    this.duration,
  });

  final MusicTrack track;
  final double width;
  final Duration? duration;

  @override
  ConsumerState<_LibraryTrackCoverThumbnail> createState() =>
      _LibraryTrackCoverThumbnailState();
}

class _LibraryTrackCoverThumbnailState
    extends ConsumerState<_LibraryTrackCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    int coverGeneration,
  ) {
    if (_lastTrackPath != widget.track.path ||
        _lastCoverGeneration != coverGeneration) {
      _lastTrackPath = widget.track.path;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = _deferLibraryCardCoverLookup(
        isMounted: () => mounted,
        lookup: () => coverUi.deferredTrackCover(widget.track),
      );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final resolution = ref.watch(
      settingsStateProvider.select(
        (s) => s.value?.coverImageResolution ?? CoverImageResolution.balanced,
      ),
    );
    final libraryFacade = ref.read(libraryFacadeProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverGeneration);
    final track = widget.track;

    final width = widget.width;
    final height = width / kStandardCoverAspectRatio;
    final coverCacheWidth = coverCacheWidthForLogicalSize(
      logicalWidth: width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: resolution,
    );
    return Stack(
      children: [
        SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              LibraryLikeCardMetrics.coverRadius,
            ),
            child: Hero(
              tag: 'cover_${track.path}',
              placeholderBuilder: (context, heroSize, child) => child,
              child: AsyncLocalCoverImage(
                future: coverPathFuture,
                requestKey: track.path,
                initialPath: libraryFacade.resolvedCoverPathForTrack(track),
                retryFutureBuilder: () => coverUi.deferredTrackCover(track),
                seed: track.displayName,
                cacheWidth: coverCacheWidth,
                useDefaultCacheWidth: false,
                fit: BoxFit.cover,
                compact: true,
                iconSize: 28,
              ),
            ),
          ),
        ),
        if (widget.duration != null && widget.duration! > Duration.zero)
          Positioned(
            right: 4,
            bottom: 4,
            child: DurationOverlay(duration: widget.duration!),
          ),
      ],
    );
  }
}

class _RootFolderCardContent extends StatelessWidget {
  const _RootFolderCardContent({
    required this.folderPath,
    required this.folderName,
    required this.folderDuration,
    required this.detail,
    required this.detailLoading,
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
    this.isSelected = false,
    this.index,
    required this.hasResolvedCover,
  });

  final String folderPath;
  final String folderName;
  final Duration folderDuration;
  final AudioDetail? detail;
  final bool detailLoading;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;
  final bool isSelected;
  final int? index;
  final bool hasResolvedCover;

  @override
  Widget build(BuildContext context) {
    return _AudioDetailWorkCardContent(
      title: folderName,
      detail: detail,
      detailLoading: detailLoading,
      expanded: expanded,
      showExpandIndicator: hasChildren,
      onPlay: onPlay,
      index: index,
      hasResolvedCover: hasResolvedCover,
      coverBuilder: (coverWidth) => Stack(
        clipBehavior: Clip.none,
        children: [
          _LibraryCoverThumbnail(
            folderPath: folderPath,
            width: coverWidth,
            duration: detail?.duration ?? folderDuration,
          ),
          if (isSelected)
            const Positioned(
              left: 4,
              bottom: 4,
              child: _LibrarySelectionIndicator(),
            ),
        ],
      ),
    );
  }
}

class _AudioDetailWorkCardContent extends ConsumerWidget {
  const _AudioDetailWorkCardContent({
    required this.title,
    required this.detail,
    required this.detailLoading,
    required this.coverBuilder,
    required this.onPlay,
    this.expanded = false,
    this.showExpandIndicator = false,
    this.index,
    this.hasResolvedCover = false,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;
  final int? index;
  final bool hasResolvedCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final fields = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.cardInfoFields ?? CardInfoField.defaults,
      ),
    );
    return LibraryLikeMetadataWorkCardContent(
      title: title,
      fields: fields,
      metadata: _audioDetailMetadata(detail),
      circleLabel: i18n.tr('library_category_circles'),
      tagsLabel: i18n.tr('library_category_tags'),
      releaseDateLabel: i18n.tr('card_info_release_date'),
      salesCountLabel: i18n.tr('card_info_sales_count'),
      ratingLabel: i18n.tr('card_info_rating'),
      loading: detailLoading || detail == null,
      coverBuilder: coverBuilder,
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: showExpandIndicator,
      playTooltip: i18n.tr('play'),
      enableMarquee: false,
      enableTitleMarquee: false,
      hasResolvedCover: hasResolvedCover,
    );
  }
}

class _SingleAudioFileCardContent extends ConsumerWidget {
  const _SingleAudioFileCardContent({
    required this.title,
    required this.detail,
    required this.detailLoading,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final fields = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.cardInfoFields ?? CardInfoField.defaults,
      ),
    );
    return LibraryLikeSingleAudioCardContent(
      title: title,
      lines: _audioDetailInfoLines(i18n, detail, detailLoading, fields),
      enableMarquee: false,
      enableTitleMarquee: false,
    );
  }
}

class _SingleMediaFileCardContent extends StatelessWidget {
  const _SingleMediaFileCardContent({
    required this.track,
    required this.title,
    required this.detail,
    required this.detailLoading,
    required this.onPlay,
    this.isSelected = false,
    this.index,
  });

  final MusicTrack track;
  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final VoidCallback onPlay;
  final bool isSelected;
  final int? index;

  @override
  Widget build(BuildContext context) {
    return _AudioDetailWorkCardContent(
      title: title,
      detail: detail,
      detailLoading: detailLoading,
      onPlay: onPlay,
      index: index,
      coverBuilder: (coverWidth) => Stack(
        clipBehavior: Clip.none,
        children: [
          _LibraryTrackCoverThumbnail(
            track: track,
            width: coverWidth,
            duration: detail?.duration ?? track.duration,
          ),
          if (isSelected)
            const Positioned(
              left: 4,
              bottom: 4,
              child: _LibrarySelectionIndicator(),
            ),
        ],
      ),
    );
  }
}

LibraryLikeInfoMetadata _audioDetailMetadata(AudioDetail? detail) {
  final d = detail;
  if (d == null) return const LibraryLikeInfoMetadata();
  return LibraryLikeInfoMetadata(
    rjCode: d.rjCode,
    voiceActors: d.voiceActors,
    circleName: d.circleName,
    tags: d.tags,
    releaseDate: d.releaseDate,
    duration: d.duration,
    salesCount: d.salesCount,
    rating: d.rating,
  );
}

List<LibraryLikeInfoLineData> _audioDetailInfoLines(
  AppLanguageProvider i18n,
  AudioDetail? detail,
  bool detailLoading,
  List<CardInfoField> fields,
) {
  final d = detail;
  if (detailLoading || d == null) {
    return const <LibraryLikeInfoLineData>[];
  }

  return buildLibraryLikeInfoLines(
    fields: fields,
    metadata: _audioDetailMetadata(d),
    circleLabel: i18n.tr('library_category_circles'),
    tagsLabel: i18n.tr('library_category_tags'),
    releaseDateLabel: i18n.tr('card_info_release_date'),
    salesCountLabel: i18n.tr('card_info_sales_count'),
    ratingLabel: i18n.tr('card_info_rating'),
  );
}
