import 'dart:math';

import '../../../../core/widgets/app_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/widgets/animated_reorder.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/widgets/playing_sound_wave_indicator.dart';
import '../../../../core/widgets/shimmer_loading.dart';
import '../../../../core/widgets/swipe_reveal_card.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../library/application/library_facade.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../playback_providers.dart';
import '../playlist_sorting.dart';
import 'playlist_feature_icons.dart';
import 'playlist_media_widgets.dart';
import 'playlist_shared_helpers.dart';

const double playlistListHorizontalPadding = AppSpacing.xs;

const Color _playlistSelectionCheckmarkColor = Color(0xFF4CAF50);

/// Scopes playlist multi-selection state to mode-only (`''`) or row-only
/// (`sessionId`) dependents so card contents do not rebuild on selection changes.
class PlaylistSelectionScope extends InheritedModel<String> {
  const PlaylistSelectionScope({
    super.key,
    required this.ids,
    required super.child,
  });

  final Set<String> ids;

  static Set<String>? maybeIdsOf(BuildContext context, {String? aspect}) =>
      InheritedModel.inheritFrom<PlaylistSelectionScope>(
        context,
        aspect: aspect,
      )?.ids;

  static bool? maybeIsSelectionModeOf(BuildContext context) =>
      maybeIdsOf(context, aspect: '')?.isNotEmpty;

  static bool? maybeIsSelectedOf(BuildContext context, String sessionId) =>
      maybeIdsOf(context, aspect: sessionId)?.contains(sessionId);

  static bool? maybeReadIsSelectionMode(BuildContext context) => context
      .getInheritedWidgetOfExactType<PlaylistSelectionScope>()
      ?.ids
      .isNotEmpty;

  @override
  bool updateShouldNotify(PlaylistSelectionScope oldWidget) =>
      !identical(ids, oldWidget.ids);

  @override
  bool updateShouldNotifyDependent(
    PlaylistSelectionScope oldWidget,
    Set<String> dependencies,
  ) {
    if (dependencies.contains('') && ids.isEmpty != oldWidget.ids.isEmpty) {
      return true;
    }
    for (final id in dependencies) {
      if (id.isNotEmpty && ids.contains(id) != oldWidget.ids.contains(id)) {
        return true;
      }
    }
    return false;
  }
}

/// Scopes pinned-session membership to individual rows by `sessionId`.
class PlaylistPinnedScope extends InheritedModel<String> {
  const PlaylistPinnedScope({
    super.key,
    required this.pinnedIds,
    required super.child,
  });

  final Set<String> pinnedIds;

  static bool? maybeIsPinnedOf(BuildContext context, String sessionId) =>
      InheritedModel.inheritFrom<PlaylistPinnedScope>(
        context,
        aspect: sessionId,
      )?.pinnedIds.contains(sessionId);

  @override
  bool updateShouldNotify(PlaylistPinnedScope oldWidget) =>
      !identical(pinnedIds, oldWidget.pinnedIds) &&
      !setEquals(pinnedIds, oldWidget.pinnedIds);

  @override
  bool updateShouldNotifyDependent(
    PlaylistPinnedScope oldWidget,
    Set<String> dependencies,
  ) => dependencies.any(
    (id) => pinnedIds.contains(id) != oldWidget.pinnedIds.contains(id),
  );
}

class PlaylistSelectionIndicator extends StatelessWidget {
  const PlaylistSelectionIndicator({
    super.key,
    required this.sessionId,
    required this.isSelected,
  });

  final String sessionId;
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
            key: ValueKey<String>('playlist_selection_indicator_$sessionId'),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _playlistSelectionCheckmarkColor,
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

class PlaylistPinnedIndicator extends StatelessWidget {
  const PlaylistPinnedIndicator({
    super.key,
    required this.sessionId,
    this.color,
    this.isPinned = true,
  });

  final String sessionId;
  final Color? color;
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pinColor = color ?? cs.primary;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AppDeferredFade(
          visible: isPinned,
          fadeInDuration: kAppMotionFast,
          waitFor: AnimatedReorder.animationOf(context),
          child: Container(
            key: ValueKey<String>('playlist_session_pinned_$sessionId'),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: pinColor,
              border: Border.all(color: cs.surface, width: 2),
            ),
            child: const Icon(
              Icons.push_pin_rounded,
              size: 13,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class PlaylistLoadingSkeleton extends StatelessWidget {
  const PlaylistLoadingSkeleton({
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
        final cardCount = max(1, (contentHeight / playlistRowHeight).ceil());
        return ListView.builder(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            playlistListHorizontalPadding,
            topPadding,
            playlistListHorizontalPadding,
            bottomPadding,
          ),
          itemCount: cardCount,
          itemBuilder: (context, index) => Container(
            key: ValueKey<String>('playlist_skeleton_card_$index'),
            height: playlistRowHeight,
            padding: playlistRowPadding,
            child: ShimmerLoader(
              child: Row(
                children: [
                  Container(
                    width: playlistCoverSize,
                    height: playlistCoverSize,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: switch (index % 4) {
                            0 => 96.0,
                            1 => 114.0,
                            2 => 84.0,
                            _ => 104.0,
                          },
                          height: 11,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: switch (index % 4) {
                            0 => 0.82,
                            1 => 0.68,
                            2 => 0.90,
                            _ => 0.74,
                          },
                          child: Container(
                            height: 14,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  SizedBox(
                    width: playlistActionContainerWidth,
                    height: playlistCoverSize,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          shape: BoxShape.circle,
                        ),
                      ),
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

class SessionsEmptyState extends StatelessWidget {
  const SessionsEmptyState({
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
          primary: defaultTargetPlatform == TargetPlatform.windows,
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
                          Icons.featured_play_list_rounded,
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
                        AppLabelledButton(
                          FilledButton.icon,
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
        ).withWindowsSmoothScroll();
      },
    );
  }
}

class PlaylistAudioRow extends StatelessWidget {
  const PlaylistAudioRow({
    super.key,
    this.contentKey,
    required this.cover,
    required this.labels,
    required this.actions,
  });

  final Key? contentKey;
  final Widget cover;
  final Widget labels;
  final Widget actions;

  @override
  Widget build(BuildContext context) => Padding(
    key: contentKey,
    padding: playlistRowPadding,
    child: Row(
      children: [
        cover,
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: labels),
        const SizedBox(width: AppSpacing.xxs),
        actions,
      ],
    ),
  );
}

class PlaylistAudioLabels extends StatelessWidget {
  const PlaylistAudioLabels({
    super.key,
    this.workTitleKey,
    required this.workTitle,
    required this.title,
    required this.semanticsLabel,
    this.titleColor,
  });

  final Key? workTitleKey;
  final String workTitle;
  final InlineSpan title;
  final String semanticsLabel;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IgnorePointer(
          child: MarqueeText(
            key: workTitleKey,
            text: workTitle,
            edgePadding: 0,
            pauseDuration: const Duration(seconds: 1),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text.rich(
          title,
          semanticsLabel: semanticsLabel,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 14,
            height: 1.12,
            color: titleColor,
          ),
        ),
      ],
    );
  }
}

class SessionListCard extends ConsumerWidget {
  const SessionListCard({
    super.key,
    required this.sessionId,
    this.session,
    required this.track,
    required this.coverCacheWidth,
    required this.library,
    required this.playback,
    required this.isTemporary,
    required this.onOpen,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.isPinned = false,
    this.onLongPress,
    this.onToggleSelect,
    this.onTogglePin,
  });

  final String sessionId;
  final PlaybackSessionSnapshot? session;
  final MusicTrack? track;
  final int? coverCacheWidth;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final bool isTemporary;
  final ValueChanged<BuildContext> onOpen;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onTogglePin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSubtitles = ref.watch(
      subtitleSettingsProvider.select(
        (settings) => settings.isGlobalEnabled(sessionId),
      ),
    );
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(playbackSessionRemovalKey(sessionId)),
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
    final workName =
        playlistSessionWorkName(
          ref.read(audioPathCoordinatorProvider),
          cardState.trackPath,
          track,
        ) ??
        i18n.tr('imported_files');
    final isPlaying = cardState.isPlaying;

    final activeColor = cs.primary;
    final resolvedSession = session ??
        ref.read(playbackSessionProvider(sessionId)) ??
        playback.sessionSnapshotById(sessionId);

    final cardColor = isTemporary
        ? playlistTemporaryCardColor(context)
        : cs.surface;

    final labelsContent = PlaylistAudioLabels(
      workTitle: workName,
      workTitleKey: ValueKey<String>('playlist_session_work_title_$sessionId'),
      title: TextSpan(
        children: [
          if (isPlaying)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: PlayingSoundWaveIndicator(
                  key: ValueKey<String>('playlist_sound_wave_$sessionId'),
                  color: activeColor,
                  isPlaying: isPlaying,
                ),
              ),
            ),
          TextSpan(text: displayName),
        ],
      ),
      semanticsLabel: displayName,
      titleColor: isPlaying ? activeColor : null,
    );

    final cardBody = MarqueePauseScope(
      isPaused: false,
      hoverToRun: defaultTargetPlatform == TargetPlatform.windows,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: playlistRowHeight),
        child: Material(
          type: MaterialType.card,
          shape: playlistRowShape,
          color: Colors.transparent,
          shadowColor: Colors.transparent,
          child: AppEntryInkWell(
            customBorder: playlistRowShape,
            excludeFromSemantics: true,
            onTap: () {
              final selectionActive = !isTemporary &&
                  (PlaylistSelectionScope.maybeReadIsSelectionMode(context) ??
                      isSelectionMode);
              if (selectionActive) {
                onToggleSelect?.call();
              } else {
                AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
                onOpen(context);
              }
            },
            // Absorb long presses on non-selectable rows so release does not
            // fall through to onTap and open the detail page.
            onLongPress: onLongPress ?? () {},
            child: PlaylistAudioRow(
              contentKey: ValueKey<String>('playlist_card_content_$sessionId'),
              cover: Stack(
                clipBehavior: Clip.none,
                children: [
                  SessionCoverProgressRing(
                    session: resolvedSession,
                    sessionId: sessionId,
                    activeColor: activeColor,
                    size: playlistCoverSize,
                    child: SessionCoverThumbnail(
                      sessionId: sessionId,
                      track: track,
                      coverCacheWidth: coverCacheWidth,
                      dimension: coverProgressInnerDimension(playlistCoverSize),
                    ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: isTemporary
                        ? PlaylistSelectionIndicator(
                            sessionId: sessionId,
                            isSelected: isSelected,
                          )
                        : Builder(
                            builder: (badgeContext) =>
                                PlaylistSelectionIndicator(
                                  sessionId: sessionId,
                                  isSelected:
                                      PlaylistSelectionScope.maybeIsSelectedOf(
                                        badgeContext,
                                        sessionId,
                                      ) ??
                                      isSelected,
                                ),
                          ),
                  ),
                  Positioned(
                    top: -2,
                    right: -2,
                    child: isTemporary
                        ? PlaylistPinnedIndicator(
                            isPinned: isPinned,
                            sessionId: sessionId,
                            color: activeColor,
                          )
                        : Builder(
                            builder: (badgeContext) => PlaylistPinnedIndicator(
                              isPinned:
                                  PlaylistPinnedScope.maybeIsPinnedOf(
                                    badgeContext,
                                    sessionId,
                                  ) ??
                                  isPinned,
                              sessionId: sessionId,
                              color: activeColor,
                            ),
                          ),
                  ),
                ],
              ),
              labels: isTemporary
                  ? Semantics(
                      button: true,
                      selected: isSelectionMode ? isSelected : null,
                      label: i18n.tr('open_playback_details'),
                      onTap: isSelectionMode
                          ? onToggleSelect
                          : () => onOpen(context),
                      onLongPress: onLongPress,
                      child: labelsContent,
                    )
                  : Builder(
                      builder: (semanticsContext) {
                        final selectionMode =
                            PlaylistSelectionScope.maybeIsSelectionModeOf(
                              semanticsContext,
                            ) ??
                            isSelectionMode;
                        final selected = selectionMode
                            ? (PlaylistSelectionScope.maybeIsSelectedOf(
                                    semanticsContext,
                                    sessionId,
                                  ) ??
                                  isSelected)
                            : null;
                        return Semantics(
                          button: true,
                          selected: selected,
                          label: i18n.tr('open_playback_details'),
                          onTap: selectionMode
                              ? onToggleSelect
                              : () => onOpen(context),
                          onLongPress: onLongPress,
                          child: labelsContent,
                        );
                      },
                    ),
              actions: SessionFeatureBadgeStack(
                featureIcons: sessionFeatureBadgeIcons(
                  showSubtitles: showSubtitles,
                  channelSwapEnabled: cardState.channelSwapEnabled,
                  audioEffects: cardState.audioEffects,
                  speed: cardState.speed,
                ),
                color: activeColor,
                child: IconButton(
                  tooltip: isPlaying ? i18n.tr('pause') : i18n.tr('play'),
                  onPressed: () {
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.selection,
                    );
                    playback.toggleSessionPlayPause(sessionId);
                  },
                  style: appIconButtonStyle(
                    IconButton.styleFrom(
                      foregroundColor: isPlaying
                          ? activeColor
                          : cs.onSurface,
                      minimumSize: const Size(44, 44),
                      maximumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  icon: AnimatedSwitcher(
                    switchOutCurve: kAppFadeCurve,
                    switchInCurve: kAppFadeCurve,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : kAppFadeDuration,
                    transitionBuilder: (child, animation) {
                      return ScaleTransition(
                        scale: Tween<double>(begin: 0.4, end: 1.0).animate(
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
                    child:
                        cardState.isLoading ||
                            cardState.playbackError != null
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
            ),
          ),
        ),
      ),
    );

    final card = isTemporary
        ? SwipeRevealCard(
            key: ValueKey(sessionId),
            shape: playlistRowShape,
            swipeEnabled: false,
            closedColor: cardColor,
            enabled: !isSelectionMode,
            actionLabel: i18n.tr('remove'),
            removeTooltip: i18n.tr('remove_audio'),
            onRemove: () =>
                stagePlaybackSessionRemovals(context, ref, [sessionId]),
            onLeadingAction: onTogglePin,
            onSelectMultiple: onLongPress,
            selectMultipleLabel: i18n.tr('select_multiple'),
            leadingActionLabel: i18n.tr(
              isPinned ? 'unpin_from_top' : 'pin_to_top',
            ),
            leadingActionTooltip: i18n.tr(
              isPinned ? 'unpin_from_top' : 'pin_to_top',
            ),
            leadingActionIcon: Icons.push_pin_rounded,
            leadingActionIconWidget: isPinned ? const PushPinOffIcon() : null,
            child: cardBody,
          )
        : Builder(
            builder: (swipeContext) {
              final selectionMode =
                  PlaylistSelectionScope.maybeIsSelectionModeOf(swipeContext) ??
                  isSelectionMode;
              final pinned =
                  PlaylistPinnedScope.maybeIsPinnedOf(
                    swipeContext,
                    sessionId,
                  ) ??
                  isPinned;
              return SwipeRevealCard(
                key: ValueKey(sessionId),
                shape: playlistRowShape,
                swipeEnabled: false,
                closedColor: cardColor,
                enabled: !selectionMode,
                actionLabel: i18n.tr('remove'),
                removeTooltip: i18n.tr('remove_audio'),
                onRemove: () =>
                    stagePlaybackSessionRemovals(context, ref, [sessionId]),
                onLeadingAction: onTogglePin,
                onSelectMultiple: onLongPress,
                selectMultipleLabel: i18n.tr('select_multiple'),
                leadingActionLabel: i18n.tr(
                  pinned ? 'unpin_from_top' : 'pin_to_top',
                ),
                leadingActionTooltip: i18n.tr(
                  pinned ? 'unpin_from_top' : 'pin_to_top',
                ),
                leadingActionIcon: Icons.push_pin_rounded,
                leadingActionIconWidget:
                    pinned ? const PushPinOffIcon() : null,
                child: cardBody,
              );
            },
          );
    return UndoableRemovalTransition(hidden: isHidden, child: card);
  }
}
