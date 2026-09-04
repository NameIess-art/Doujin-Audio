part of 'playlist_tab.dart';

const double _playlistRowHeight = 88;
const double _playlistCoverSize = 72;
const double _playlistListHorizontalPadding = AppSpacing.xs;
const EdgeInsets _playlistRowPadding = EdgeInsets.all(AppSpacing.xs);
const RoundedRectangleBorder _playlistRowShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(
    Radius.circular(LibraryLikeCardMetrics.cardRadius),
  ),
);

const Color _playlistSelectionCheckmarkColor = Color(0xFF4CAF50);

class _PlaylistSelectionIndicator extends StatelessWidget {
  const _PlaylistSelectionIndicator({
    required this.sessionId,
    required this.isSelected,
  });

  final String sessionId;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionFast;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.65, end: 1).animate(animation),
                child: child,
              ),
            );
          },
          child: isSelected
              ? Container(
                  key: ValueKey<String>(
                    'playlist_selection_indicator_$sessionId',
                  ),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _playlistSelectionCheckmarkColor,
                    border: Border.all(color: Colors.white, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                )
              : const SizedBox.shrink(
                  key: ValueKey<String>('playlist_selection_indicator_hidden'),
                ),
        ),
      ),
    );
  }
}

class _PlaylistPinnedIndicator extends StatelessWidget {
  const _PlaylistPinnedIndicator({
    required this.sessionId,
    this.color,
  });

  final String sessionId;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pinColor = color ?? cs.primary;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey<String>('playlist_session_pinned_$sessionId'),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pinColor,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: const Icon(
            Icons.push_pin_rounded,
            size: 11,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _PushPinOffIcon extends StatelessWidget {
  const _PushPinOffIcon();

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final effectiveSize = iconTheme.size ?? 22.0;
    final effectiveColor =
        iconTheme.color ?? Theme.of(context).colorScheme.onSurface;

    return SizedBox(
      width: effectiveSize,
      height: effectiveSize,
      child: CustomPaint(
        painter: _PushPinOffPainter(
          iconColor: effectiveColor,
          size: effectiveSize,
        ),
      ),
    );
  }
}

class _PushPinOffPainter extends CustomPainter {
  const _PushPinOffPainter({
    required this.iconColor,
    required this.size,
  });

  final Color iconColor;
  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Offset.zero & canvasSize;
    canvas.saveLayer(rect, Paint());

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(Icons.push_pin_rounded.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: Icons.push_pin_rounded.fontFamily,
          package: Icons.push_pin_rounded.fontPackage,
          color: iconColor,
        ),
      ),
    )..layout();

    final textOffset = Offset(
      (canvasSize.width - textPainter.width) / 2,
      (canvasSize.height - textPainter.height) / 2,
    );
    textPainter.paint(canvas, textOffset);

    final scale = size / 24.0;
    final p1 = Offset(3.5 * scale, 3.5 * scale);
    final p2 = Offset(20.5 * scale, 20.5 * scale);

    final clearPaint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = 3.2 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, clearPaint);

    final linePaint = Paint()
      ..color = iconColor
      ..strokeWidth = 1.8 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, linePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PushPinOffPainter oldDelegate) {
    return oldDelegate.iconColor != iconColor || oldDelegate.size != size;
  }
}

class _PlaylistLeadingIndicators extends StatelessWidget {
  const _PlaylistLeadingIndicators({
    required this.sessionId,
    required this.isSelected,
    required this.isPinned,
    this.isSelectionMode = false,
    this.pinColor,
  });

  final String sessionId;
  final bool isSelected;
  final bool isPinned;
  final bool isSelectionMode;
  final Color? pinColor;

  @override
  Widget build(BuildContext context) {
    final showLeading = isPinned || isSelected || isSelectionMode;
    if (!showLeading) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: SizedBox(
        width: 24,
        height: _playlistCoverSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (isPinned)
              Positioned(
                top: 4,
                left: 2,
                child: _PlaylistPinnedIndicator(
                  sessionId: sessionId,
                  color: pinColor,
                ),
              ),
            Positioned(
              bottom: 4,
              left: 0,
              child: _PlaylistSelectionIndicator(
                sessionId: sessionId,
                isSelected: isSelected,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

LinearGradient _playlistActiveHighlightGradient(
  bool isPlaying,
  Color highlightColor,
) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: isPlaying
      ? <Color>[
          highlightColor,
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
        ]
      : const <Color>[
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
        ],
);

class _PlaylistLoadingSkeleton extends StatelessWidget {
  const _PlaylistLoadingSkeleton({
    super.key,
    required this.topPadding,
    required this.bottomPadding,
  });

  final double topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentHeight = max(
          0.0,
          constraints.maxHeight - topPadding - bottomPadding,
        );
        final cardCount = max(1, (contentHeight / _playlistRowHeight).ceil());
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            _playlistListHorizontalPadding,
            topPadding,
            _playlistListHorizontalPadding,
            bottomPadding,
          ),
          itemCount: cardCount,
          itemBuilder: (context, index) => Container(
            key: ValueKey<String>('playlist_skeleton_card_$index'),
            height: _playlistRowHeight,
            padding: _playlistRowPadding,
            child: ShimmerLoader(
              child: Row(
                children: [
                  Container(
                    width: _playlistCoverSize,
                    height: _playlistCoverSize,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: AppRadius.borderCard,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 94,
                          height: 9,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          height: 13,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: 136,
                          height: 10,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(5),
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
      },
    );
  }
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({
    super.key,
    required this.bottomInset,
    this.onOpenLibrary,
    this.topInset = 16,
  });

  final double bottomInset;
  final VoidCallback? onOpenLibrary;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight - topInset - bottomInset;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl,
            topInset,
            AppSpacing.xl,
            bottomInset,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: availableHeight > 0 ? availableHeight : 0,
            ),
            child: Center(
              child: Container(
                key: const ValueKey('playlist_empty_state_card'),
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: AppRadius.borderDialog,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      cs.surfaceContainerHigh.withValues(alpha: 0.6),
                      cs.surfaceContainerLow.withValues(alpha: 0.4),
                    ],
                  ),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.1),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    42,
                    AppSpacing.xl,
                    42,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              cs.primaryContainer,
                              cs.primaryContainer.withValues(alpha: 0.8),
                            ],
                          ),
                          borderRadius: AppRadius.borderDialog,
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withValues(alpha: 0.12),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.queue_music_rounded,
                          size: 36,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        i18n.tr('no_active_sessions'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        i18n.tr('go_library_hint'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      if (onOpenLibrary != null) ...[
                        const SizedBox(height: AppSpacing.lg),
                        FilledButton.icon(
                          onPressed: onOpenLibrary,
                          icon: const Icon(Icons.library_music_rounded),
                          label: Text(i18n.tr('open_library')),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionListCard extends ConsumerWidget {
  const _SessionListCard({
    required this.sessionId,
    required this.track,
    required this.coverPath,
    required this.coverGeneration,
    required this.coverCacheWidth,
    required this.showSubtitles,
    required this.library,
    required this.playback,
    required this.onOpen,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.isPinned = false,
    this.onLongPress,
    this.onToggleSelect,
    this.onTogglePin,
  });

  final String sessionId;
  final MusicTrack? track;
  final String? coverPath;
  final int coverGeneration;
  final int? coverCacheWidth;
  final bool showSubtitles;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final VoidCallback onOpen;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onTogglePin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(_playbackSessionRemovalKey(sessionId)),
    );
    final cardState = ref.watch(playlistSessionCardStateProvider(sessionId));
    if (cardState == null) return const SizedBox.shrink();
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(cardState.trackPath);
    final currentTrack = track;
    final rootFolderName = ref
        .read(audioPathCoordinatorProvider)
        .rootFolderName(cardState.trackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (currentTrack != null && !currentTrack.isSingle)
        ? currentTrack.groupTitle
        : i18n.tr('imported_files');
    final isPlaying = cardState.isPlaying;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAsmrOne = currentTrack?.remoteMetadataKind == 'asmr.one';
    final detailDuration =
        currentTrack == null || isAsmrOne || !currentTrack.isSingle
        ? null
        : ref.watch(
            libraryDetailForTargetProvider(
              ref
                  .read(libraryFacadeProvider)
                  .audioDetailTargetForTrack(currentTrack),
            ).select((state) => state.value?.duration),
          );
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final localPlayRose = cs.primary;

    final highlightColor = isAsmrOne
        ? asmrBlue.withValues(alpha: isDark ? 0.18 : 0.14)
        : localPlayRose.withValues(alpha: isDark ? 0.16 : 0.12);
    final activeColor = isAsmrOne ? asmrBlue : localPlayRose;
    final showCover = shouldShowPlaylistCoverArtwork(track, coverPath);

    return UndoableRemovalTransition(
      hidden: isHidden,
      child: SwipeRevealCard(
        key: ValueKey(sessionId),
        shape: _playlistRowShape,
        closedColor: cs.surface,
        enabled: !isSelectionMode,
        actionLabel: i18n.tr('remove'),
        removeTooltip: i18n.tr('remove_audio'),
        onRemove: () => _stagePlaybackSessionRemovals(context, ref, [sessionId]),
        onLeadingAction: onTogglePin,
        leadingActionLabel: i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top'),
        leadingActionTooltip:
            i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top'),
        leadingActionIcon: Icons.push_pin_rounded,
        leadingActionIconWidget: isPinned ? const _PushPinOffIcon() : null,
        child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _playlistRowHeight),
        child: Material(
          color: Colors.transparent,
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: _playlistRowShape,
            color: Colors.transparent,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: DecoratedBox(
              key: ValueKey<String>('playlist_card_highlight_$sessionId'),
              decoration: BoxDecoration(
                gradient: _playlistActiveHighlightGradient(
                  isPlaying,
                  highlightColor,
                ),
                color: isSelected
                    ? cs.primaryContainer.withValues(alpha: 0.15)
                    : null,
                borderRadius: const BorderRadius.all(
                  Radius.circular(LibraryLikeCardMetrics.cardRadius),
                ),
              ),
              child: InkWell(
                excludeFromSemantics: true,
                onTap: () {
                  if (isSelectionMode) {
                    onToggleSelect?.call();
                  } else {
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.tap,
                    );
                    onOpen();
                  }
                },
                onLongPress: () {
                  if (isSelectionMode) {
                    onToggleSelect?.call();
                  } else {
                    onLongPress?.call();
                  }
                },
                child: Padding(
                  key: ValueKey<String>('playlist_card_content_$sessionId'),
                  padding: _playlistRowPadding,
                  child: Row(
                    children: [
                      if (showCover) ...[
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _SessionCoverThumbnail(
                              sessionId: sessionId,
                              track: track,
                              coverPath: coverPath,
                              coverGeneration: coverGeneration,
                              coverCacheWidth: coverCacheWidth,
                              duration: track?.duration,
                              detailDuration: detailDuration,
                            ),
                            Positioned(
                              left: 4,
                              bottom: 4,
                              child: _PlaylistSelectionIndicator(
                                sessionId: sessionId,
                                isSelected: isSelected,
                              ),
                            ),
                            if (isPinned)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: _PlaylistPinnedIndicator(
                                  sessionId: sessionId,
                                  color: isAsmrOne ? asmrBlue : localPlayRose,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ] else ...[
                        _PlaylistLeadingIndicators(
                          sessionId: sessionId,
                          isSelected: isSelected,
                          isPinned: isPinned,
                          isSelectionMode: isSelectionMode,
                          pinColor: isAsmrOne ? asmrBlue : localPlayRose,
                        ),
                      ],
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: isSelectionMode ? isSelected : null,
                          label: i18n.tr('open_playback_details'),
                          onTap: isSelectionMode ? onToggleSelect : onOpen,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                folderName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      height: 1.12,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 10,
                                runSpacing: 2,
                                children: [
                                  _SessionMetaChip(
                                    icon: Icons.repeat_rounded,
                                    text: _playlistLoopModeSummary(
                                      context,
                                      cardState.loopMode,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SessionFeatureBadgeStack(
                                featureIcons: sessionFeatureBadgeIcons(
                                  showSubtitles: showSubtitles,
                                  channelSwapEnabled:
                                      cardState.channelSwapEnabled,
                                  audioEffects: cardState.audioEffects,
                                  speed: cardState.speed,
                                ),
                                color: isAsmrOne ? asmrBlue : localPlayRose,
                                child: IconButton(
                                  tooltip: isPlaying
                                      ? i18n.tr('pause')
                                      : i18n.tr('play'),
                                  onPressed: () {
                                    AppInteractionFeedback.trigger(
                                      AppInteractionFeedbackType.selection,
                                    );
                                    playback.toggleSessionPlayPause(sessionId);
                                  },
                                  style: IconButton.styleFrom(
                                    foregroundColor: isPlaying
                                        ? activeColor
                                        : cs.onSurface,
                                    minimumSize: const Size(44, 44),
                                    maximumSize: const Size(44, 44),
                                    padding: EdgeInsets.zero,
                                  ),
                                  icon: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 120),
                                    transitionBuilder: (child, animation) {
                                      return ScaleTransition(
                                        scale:
                                            Tween<double>(
                                              begin: 0.4,
                                              end: 1.0,
                                            ).animate(
                                              CurvedAnimation(
                                                parent: animation,
                                                curve: Curves.easeOutBack,
                                              ),
                                            ),
                                        child: FadeTransition(
                                          opacity: animation,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: cardState.isLoading
                                        ? const SizedBox(
                                            key: ValueKey('loading'),
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.3,
                                            ),
                                          )
                                        : Icon(
                                            isPlaying
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            key: ValueKey(isPlaying),
                                            size: 28,
                                          ),
                                  ),
                                ),
                              ),
                              if (cardState.playbackError != null)
                                Text(
                                  i18n.tr('playback_failed_retry'),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: cs.error),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  }
}
