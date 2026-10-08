part of 'asmr_tab.dart';

const Color _asmrSelectionCheckmarkColor = Color(0xFF4CAF50);
const Duration _asmrSelectionFadeDuration = Duration(milliseconds: 450);

class _AsmrSelectionIndicator extends StatelessWidget {
  const _AsmrSelectionIndicator({
    this.workId,
    this.isSelected = true,
  });

  final String? workId;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _asmrSelectionFadeDuration;
    final surfaceBorderColor = isSelected
        ? Color.alphaBlend(
            cs.primaryContainer.withValues(alpha: 0.15),
            cs.surface,
          )
        : cs.surface;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          child: isSelected
              ? Container(
                  key: workId == null
                      ? const ValueKey<String>('asmr_selection_indicator')
                      : ValueKey<String>('asmr_selection_indicator_$workId'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _asmrSelectionCheckmarkColor,
                    border: Border.all(color: surfaceBorderColor, width: 2),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                )
              : SizedBox.shrink(
                  key: workId == null
                      ? const ValueKey<String>('asmr_selection_indicator_hidden')
                      : ValueKey<String>(
                          'asmr_selection_indicator_hidden_$workId',
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

  Future<void> _toggleFavorite(BuildContext context) async {
    final wasFavorite = widget.work.isFavorite;
    await _toggleAsmrWorksFavorite(ref, [widget.work]);
    if (!context.mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr(wasFavorite ? 'asmr_favorite_removed' : 'asmr_favorite_added'),
      tone: wasFavorite ? AppFeedbackTone.info : AppFeedbackTone.success,
      icon: wasFavorite
          ? Icons.favorite_border_rounded
          : Icons.favorite_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    const cardShape = LibraryLikeCardMetrics.cardShape;

    final cardContent = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.hardEdge,
      shape: cardShape,
      color: widget.isSelected
          ? cs.primaryContainer.withValues(alpha: 0.25)
          : Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // The tap surface sits inside the card so its ink highlight and ripple
      // paint above the swipe card's closed background.
      child: InkWell(
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
              query: widget.searchQuery,
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
                  url: _asmrWorkListCoverUrl(widget.work),
                  width: coverWidth,
                  duration: widget.work.duration,
                  isSelected: widget.isSelected,
                  rjCode: widget.work.rjCode,
                ),
                accentColor: asmrBlue,
              ),
            ),
          ),
        ),
      ),
    );

    return SwipeRevealCard(
      shape: cardShape,
      enabled: !widget.isSelectionMode,
      closedColor: cs.surface,
      destructive: false,
      color: asmrBlue,
      verticalActions: true,
      actionLabel: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_favorite_action',
      ),
      removeTooltip: i18n.tr(
        widget.work.isFavorite
            ? 'asmr_unfavorite_action'
            : 'asmr_favorite_action',
      ),
      primaryActionIcon: widget.work.isFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      onRemove: () => unawaited(_toggleFavorite(context)),
      secondaryActionLabel: i18n.tr('download'),
      secondaryActionTooltip: i18n.tr('download'),
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
    tags: work.tags,
    releaseDate: work.releaseDate,
    rating: work.rating,
  );
}
