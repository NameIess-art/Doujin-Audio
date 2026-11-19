part of 'asmr_tab.dart';

const Color _asmrSelectionCheckmarkColor = Color(0xFF4CAF50);

class _AsmrSelectionIndicator extends StatelessWidget {
  const _AsmrSelectionIndicator({this.workId, this.isSelected = true});

  final String? workId;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AppDeferredFade(
          visible: isSelected,
          beginScale: 0.86,
          fadeInDuration: kAppMotionFast,
          child: Container(
            key: workId == null
                ? const ValueKey<String>('asmr_selection_indicator')
                : ValueKey<String>('asmr_selection_indicator_$workId'),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _asmrSelectionCheckmarkColor,
              border: Border.all(color: cs.surface, width: 2),
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrWorkTreeCard extends ConsumerStatefulWidget {
  const _AsmrWorkTreeCard({
    required this.work,
    required this.searchQuery,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  final AsmrWork work;
  final String searchQuery;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  @override
  ConsumerState<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends ConsumerState<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = LibraryLikeCardMetrics.rootTileHeight;
  bool _runningAction = false;

  Future<void> _runAction({required bool play}) async {
    if (_runningAction || widget.isSelectionMode) return;
    final playback = ref.read(asmrPlaybackCoordinatorProvider);
    if (playback == null) return;
    setState(() => _runningAction = true);
    int? requestEpoch;
    try {
      if (play) {
        requestEpoch = playback.directPlayEpoch + 1;
        final started = await playback.playDirectWork(widget.work);
        if (!started && playback.directPlayEpoch <= requestEpoch) {
          throw StateError('The work could not be played.');
        }
      } else {
        await _addAsmrWorksToPlaylist(
          context: context,
          ref: ref,
          works: [widget.work],
        );
      }
    } catch (_) {
      if (play &&
          requestEpoch != null &&
          playback.directPlayEpoch > requestEpoch) {
        return;
      }
      if (!mounted) return;
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _runningAction = false);
    }
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    await setAsmrWorksFavoriteWithFeedback(context, ref, [widget.work]);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final actionsEnabled =
        !widget.isSelectionMode &&
        !_runningAction &&
        ref.watch(asmrPlaybackCoordinatorProvider) != null;
    const cardShape = LibraryLikeCardMetrics.cardShape;

    // The card shell already clips the rounded card; keep its ink surface
    // rectangular so each scrolling row avoids another shaped physical layer.
    final cardContent = Material(
      color: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // The tap surface sits inside the card so its ink highlight and ripple
      // paint above the card's closed background.
      child: AppEntryInkWell(
        canRequestFocus: widget.isSelectionMode,
        onLongPress: widget.onLongPress,
        onTap: widget.isSelectionMode
            ? widget.onToggleSelect
            : () => unawaited(showAsmrWorkDetailSheet(context, widget.work)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _rootTileHeight),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: SearchHighlightScope(
              query: searchElementHighlight(widget.searchQuery),
              child: LibraryLikeMetadataWorkCardContent(
                title: widget.work.title,
                metadata: _workMetadata(widget.work),
                voiceActorLabel: i18n.tr('card_info_voice_actors'),
                circleLabel: i18n.tr('asmr_circle_label'),
                tagsLabel: i18n.tr('asmr_tags_label'),
                releaseDateLabel: i18n.tr('card_info_release_date'),
                ratingLabel: i18n.tr('card_info_rating'),
                listSeparator: '\u3001',
                coverBuilder: (coverWidth) => _AsmrWorkCover(
                  workKey: widget.work.workKey,
                  url: _asmrWorkListCoverUrl(widget.work),
                  width: coverWidth,
                  duration: widget.work.duration,
                  isSelected: widget.isSelected,
                ),
                accentColor: cs.primary,
                trailingActions: LibraryLikeCardActions(
                  addLabel: i18n.tr('add'),
                  playLabel: i18n.tr('play'),
                  onAdd: actionsEnabled
                      ? () => unawaited(_runAction(play: false))
                      : null,
                  onPlay: actionsEnabled
                      ? () => unawaited(_runAction(play: true))
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final favoriteLabel = i18n.tr(
      widget.work.isFavorite
          ? 'asmr_unfavorite_action'
          : 'asmr_favorite_action',
    );
    return SwipeRevealCard(
      onSelectMultiple: widget.onLongPress,
      selectMultipleLabel: i18n.tr('select_multiple'),
      shape: cardShape,
      enabled: !widget.isSelectionMode,
      closedColor: cs.surface,
      destructive: false,
      swipeEnabled: false,
      actionLabel: favoriteLabel,
      removeTooltip: favoriteLabel,
      primaryActionIcon: widget.work.isFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      onRemove: () => unawaited(_toggleFavorite(context)),
      secondaryActionLabel: i18n.tr('download'),
      secondaryActionIcon: Icons.download_rounded,
      onSecondaryAction: () =>
          unawaited(_downloadAsmrWorks(context, [widget.work])),
      child: cardContent,
    );
  }
}

LibraryLikeInfoMetadata _workMetadata(AsmrWork work) {
  return LibraryLikeInfoMetadata(
    voiceActors: work.voiceActors,
    circleName: work.circleName,
    workCode: work.workCode,
    tags: work.tags,
    releaseDate: work.releaseDate,
    rating: work.rating,
  );
}
