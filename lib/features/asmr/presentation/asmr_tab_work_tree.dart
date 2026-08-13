part of 'asmr_tab.dart';

class _AsmrWorkTreeCard extends ConsumerStatefulWidget {
  const _AsmrWorkTreeCard({
    required this.work,
    required this.searchQuery,
    required this.isActive,
    required this.expanded,
    required this.onExpansionChanged,
  });

  final AsmrWork work;
  final String searchQuery;
  final bool isActive;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  ConsumerState<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends ConsumerState<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = LibraryLikeCardMetrics.rootTileHeight;
  final ExpansibleController _expansionController = ExpansibleController();

  @override
  void didUpdateWidget(covariant _AsmrWorkTreeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.expanded) {
        _expansionController.expand();
      } else {
        _expansionController.collapse();
      }
    });
  }

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return widget.isActive ? ref.watch(provider) : ref.read(provider);
  }

  Future<void> _loadTrackTree() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final state = controller.trackTreeViewState(widget.work.id);
    if (state.isLoading || state.tree != null) return;
    try {
      await ref
          .read(uiOperationServiceProvider)
          .run<List<AsmrTrackFile>>(
            scope: UiOperationScope.asmrWork(
              AsmrOperationKind.trackTree,
              widget.work.id,
            ),
            labelKey: 'loading_dot',
            task: (_) => controller.ensureTrackTree(widget.work),
          );
    } catch (_) {
      // The controller retains the per-work error for the expanded retry state.
    }
  }

  Future<void> _playWork(BuildContext context) async {
    final playback = ref.read(asmrPlaybackCoordinatorProvider);
    if (playback == null) return;
    await ref
        .read(uiOperationServiceProvider)
        .run<void>(
          scope: UiOperationScope.asmrWork(
            AsmrOperationKind.play,
            widget.work.id,
          ),
          labelKey: 'loading_dot',
          task: (_) => playback.playWork(widget.work),
        );
    if (!context.mounted) {
      return;
    }
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': widget.work.title}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final shouldFavorite = !widget.work.isFavorite;
    final scope = UiOperationScope.asmrWork(
      AsmrOperationKind.favorite,
      widget.work.id,
    );
    final operations = ref.read(uiOperationServiceProvider);
    if (operations.isBusy(scope)) return;
    try {
      await operations.run<void>(
        scope: scope,
        labelKey: 'loading_dot',
        task: (_) => controller.toggleFavorite(widget.work),
        cancelPrevious: false,
      );
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.warning,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    if (!context.mounted) return;
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
    await Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        style: AppPageTransitionStyle.sharedAxisZ,
        child: AsmrDownloadPage(work: widget.work),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _readOrWatch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final playBusy = _readOrWatch(
      uiOperationForScopeProvider(
        UiOperationScope.asmrWork(AsmrOperationKind.play, widget.work.id),
      ),
    ).isBusy;
    final fields = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.cardInfoFields ?? CardInfoField.defaults,
      ),
    );
    const cardShape = LibraryLikeCardMetrics.cardShape;

    return SwipeRevealCard(
      shape: cardShape,
      color: asmrBlue,
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
      closedColor: cs.surface,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.hardEdge,
        shape: cardShape,
        color: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            initiallyExpanded: widget.expanded,
            expansionAnimationStyle: appExpansionAnimationStyle(context),
            minTileHeight: _rootTileHeight,
            onExpansionChanged: (expanded) {
              if (widget.expanded == expanded) {
                return;
              }
              widget.onExpansionChanged(expanded);
              if (expanded) {
                unawaited(_loadTrackTree());
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
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 0, 0),
            title: SearchHighlightScope(
              query: widget.searchQuery,
              child: LibraryLikeMetadataWorkCardContent(
                title: widget.work.title,
                fields: fields,
                metadata: _workMetadata(widget.work),
                circleLabel: i18n.tr('asmr_circle_label'),
                tagsLabel: i18n.tr('asmr_tags_label'),
                releaseDateLabel: i18n.tr('card_info_release_date'),
                salesCountLabel: i18n.tr('card_info_sales_count'),
                ratingLabel: i18n.tr('card_info_rating'),
                listSeparator: '\u3001',
                coverBuilder: (coverWidth) => _AsmrWorkCover(
                  url: _asmrWorkListCoverUrl(widget.work),
                  width: coverWidth,
                  duration: widget.work.duration,
                  isActive: widget.isActive,
                ),
                onPlay: () => unawaited(_playWork(context)),
                expanded: widget.expanded,
                showExpandIndicator: true,
                playTooltip: i18n.tr('asmr_add_to_playlist'),
                accentColor: asmrBlue,
                enableMarquee: false,
                enableTitleMarquee: false,
                playLoading: playBusy,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrTrackTreeNode extends ConsumerWidget {
  const _AsmrTrackTreeNode({
    required this.work,
    required this.node,
    required this.isActive,
    required this.expanded,
    required this.onExpansionChanged,
  });

  final AsmrWork work;
  final AsmrTrackFile node;
  final bool isActive;
  final bool expanded;
  final ValueChanged<bool>? onExpansionChanged;
  static const double _childFolderTileHeight = 44;
  static const double _childFolderTitleBlockHeight = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (node.isFolder) {
      final hasVisibleChildren = node.children.any(
        (child) => child.hasBrowsableContent,
      );
      final cs = Theme.of(context).colorScheme;
      final asmrBlue = AppDesignTokens.of(context).asmrAccent;
      final operationProvider = uiOperationForScopeProvider(
        _trackPlayScope(work, node),
      );
      final busy =
          (isActive
                  ? ref.watch(operationProvider)
                  : ref.read(operationProvider))
              .isBusy;
      return SizedBox(
        height: _childFolderTileHeight,
        child: InkWell(
          onTap: hasVisibleChildren
              ? () => onExpansionChanged?.call(!expanded)
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
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
                          node.title,
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
                SizedBox(
                  width: 62,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: busy
                            ? null
                            : () => unawaited(_playFolder(context, ref)),
                        visualDensity: VisualDensity.compact,
                        tooltip: ref
                            .read(appLanguageProviderInstanceProvider)
                            .tr('asmr_add_to_playlist'),
                        style: IconButton.styleFrom(
                          foregroundColor: asmrBlue,
                          minimumSize: const Size(40, 44),
                          maximumSize: const Size(40, 44),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: busy
                            ? SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: asmrBlue,
                                ),
                              )
                            : const Icon(Icons.add_circle_rounded, size: 25),
                      ),
                      const SizedBox(width: 2),
                      if (hasVisibleChildren)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: IgnorePointer(
                            child: AnimatedRotation(
                              turns: expanded ? 0.5 : 0,
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
              ],
            ),
          ),
        ),
      );
    }
    return _AsmrTrackLeafRow(work: work, node: node, isActive: isActive);
  }

  Future<void> _playFolder(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    final playbackCoordinator = ref.read(asmrPlaybackCoordinatorProvider);
    if (controller == null || playbackCoordinator == null) return;
    final tracks = controller.buildPlayableTracksFromNode(work, node);
    if (!context.mounted || tracks.isEmpty) {
      return;
    }
    await ref
        .read(uiOperationServiceProvider)
        .run<void>(
          scope: _trackPlayScope(work, node),
          labelKey: 'loading_dot',
          task: (_) => playbackCoordinator.playTracks(work, tracks),
        );
    if (!context.mounted) {
      return;
    }
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrTrackLeafRow extends ConsumerWidget {
  const _AsmrTrackLeafRow({
    required this.work,
    required this.node,
    required this.isActive,
  });

  final AsmrWork work;
  final AsmrTrackFile node;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final operationProvider = uiOperationForScopeProvider(
      _trackPlayScope(work, node),
    );
    final busy =
        (isActive ? ref.watch(operationProvider) : ref.read(operationProvider))
            .isBusy;
    return ColoredBox(
      color: Colors.transparent,
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
                onPressed: busy
                    ? null
                    : () => unawaited(_playTrack(context, ref)),
                style: IconButton.styleFrom(
                  foregroundColor: asmrBlue,
                  minimumSize: const Size(36, 36),
                  maximumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: asmrBlue,
                        ),
                      )
                    : const Icon(Icons.add_circle_rounded, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playTrack(BuildContext context, WidgetRef ref) async {
    final playback = ref.read(asmrPlaybackCoordinatorProvider);
    if (playback == null) return;
    await ref
        .read(uiOperationServiceProvider)
        .run<void>(
          scope: _trackPlayScope(work, node),
          labelKey: 'loading_dot',
          task: (_) => playback.playTrack(work, node),
        );
    if (!context.mounted) {
      return;
    }
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('asmr_added_to_playlist', {'title': node.displayTitle}),
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

UiOperationScope _trackPlayScope(AsmrWork work, AsmrTrackFile node) {
  return UiOperationScope('asmr:play:${work.id}:${node.relativePath}');
}

LibraryLikeInfoMetadata _workMetadata(AsmrWork work) {
  return LibraryLikeInfoMetadata(
    rjCode: work.rjCode,
    voiceActors: work.voiceActors,
    circleName: work.circleName,
    tags: work.tags,
    releaseDate: work.releaseDate,
    duration: work.duration,
    salesCount: work.dlCount,
    rating: work.rating,
  );
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
