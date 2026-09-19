part of 'asmr_tab.dart';

class _AsmrSelectionIndicator extends StatelessWidget {
  const _AsmrSelectionIndicator();

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

class _AsmrWorkTreeCard extends ConsumerStatefulWidget {
  const _AsmrWorkTreeCard({
    required this.work,
    required this.searchQuery,
    required this.isActive,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  final AsmrWork work;
  final String searchQuery;
  final bool isActive;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  @override
  ConsumerState<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends ConsumerState<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = LibraryLikeCardMetrics.rootTileHeight;

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return widget.isActive ? ref.watch(provider) : ref.read(provider);
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
    const cardShape = LibraryLikeCardMetrics.cardShape;

    return InkWell(
      canRequestFocus: widget.isSelectionMode,
      onLongPress: widget.onLongPress,
      onTap: widget.isSelectionMode
          ? widget.onToggleSelect
          : () => unawaited(showAsmrWorkDetailSheet(context, widget.work)),
      borderRadius: cardShape.borderRadius as BorderRadius?,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.hardEdge,
        shape: cardShape,
        color: widget.isSelected
            ? cs.primaryContainer.withValues(alpha: 0.25)
            : Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: LibraryLikeCardMetrics.rootTilePadding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _rootTileHeight),
            child: SearchHighlightScope(
              query: widget.searchQuery,
              child: LibraryLikeMetadataWorkCardContent(
                title: widget.work.title,
                metadata: _workMetadata(widget.work),
                circleLabel: i18n.tr('asmr_circle_label'),
                tagsLabel: i18n.tr('asmr_tags_label'),
                releaseDateLabel: i18n.tr('card_info_release_date'),
                ratingLabel: i18n.tr('card_info_rating'),
                listSeparator: '\u3001',
                coverBuilder: (coverWidth) => _AsmrWorkCover(
                  url: _asmrWorkListCoverUrl(widget.work),
                  width: coverWidth,
                  duration: widget.work.duration,
                  isActive: widget.isActive,
                  isSelected: widget.isSelected,
                  rjCode: widget.work.rjCode,
                ),
                onPlay: () => unawaited(_playWork(context)),
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

LibraryLikeInfoMetadata _workMetadata(AsmrWork work) {
  return LibraryLikeInfoMetadata(
    voiceActors: work.voiceActors,
    circleName: work.circleName,
    tags: work.tags,
    releaseDate: work.releaseDate,
    rating: work.rating,
  );
}
