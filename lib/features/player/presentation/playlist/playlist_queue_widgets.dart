import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../../core/widgets/playing_sound_wave_indicator.dart';
import '../../../../core/widgets/swipe_reveal_card.dart';
import '../../../library/application/library_facade.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/playback_queue.dart';
import '../playback_providers.dart';
import 'playlist_feature_icons.dart';
import 'playlist_list_view.dart';
import 'playlist_media_widgets.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_cover.dart';
import 'session_cover_transition.dart';
export 'playback_queue_edit_page.dart'
    show PlaybackQueueEditPage, showPlaybackQueueEditPanel;
export 'playback_queue_audio_edit_page.dart' show PlaybackQueueAudioEditPage;

class PlaybackQueueCard extends ConsumerStatefulWidget {
  const PlaybackQueueCard({
    super.key,
    required this.session,
    required this.library,
    required this.playback,
    required this.coverCacheWidth,
    required this.onOpen,
    required this.onEdit,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.isPinned = false,
    this.onLongPress,
    this.onToggleSelect,
    this.onTogglePin,
  });

  final PlaybackSessionSnapshot session;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final int? coverCacheWidth;
  final ValueChanged<BuildContext> onOpen;
  final FutureOr<void> Function() onEdit;
  final bool isSelectionMode;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onTogglePin;

  @override
  ConsumerState<PlaybackQueueCard> createState() => _PlaybackQueueCardState();
}

class _PlaybackQueueCardState extends ConsumerState<PlaybackQueueCard> {
  static final _coverSelections = Expando<_QueueCoverSelection>();
  final Map<String, Future<String?>> _coverFutures = {};
  late final _coverScanKey = 'queue_cover_scan:${identityHashCode(this)}';
  _QueueCoverSelection? _coverSelection;

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_coverScanKey);
    super.dispose();
  }

  void _scheduleCoverScan(_QueueCoverSelection selection) {
    if (selection.isComplete) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _coverScanKey,
      structural: true,
      commit: () {
        if (!mounted ||
            !identical(_coverSelection, selection) ||
            !TickerMode.getValuesNotifier(context).value.enabled) {
          return;
        }
        if (selection.scan()) setState(() {});
        _scheduleCoverScan(selection);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final library = widget.library;
    final playback = widget.playback;
    final coverCacheWidth = widget.coverCacheWidth;
    final onOpen = widget.onOpen;
    final onEdit = widget.onEdit;
    final showSubtitles = ref.watch(
      subtitleSettingsProvider.select(
        (settings) => settings.isGlobalEnabled(session.id),
      ),
    );
    final isSelectionMode = widget.isSelectionMode;
    final isSelected = widget.isSelected;
    final isPinned = widget.isPinned;
    final onLongPress = widget.onLongPress;
    final onToggleSelect = widget.onToggleSelect;
    final onTogglePin = widget.onTogglePin;
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(playbackSessionRemovalKey(session.id)),
    );
    final cardState = ref.watch(playlistSessionCardStateProvider(session.id));
    final queueState = ref.watch(
      playbackSessionProvider(session.id).select(
        (session) => (
          queue: session?.playbackQueue,
          currentIndex: session?.currentQueueIndex ?? -1,
        ),
      ),
    );
    final queue = queueState.queue;
    if (cardState == null || queue == null) return const SizedBox.shrink();
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final coverGeneration = ref.watch(coverGenerationProvider);
    var selection = _coverSelections[queue];
    if (selection == null ||
        !identical(selection.library, library) ||
        selection.generation != coverGeneration) {
      selection = _QueueCoverSelection(queue.entries, library, coverGeneration);
      selection.scan();
      _coverSelections[queue] = selection;
    }
    if (!identical(_coverSelection, selection)) {
      _coverFutures.clear();
      _coverSelection = selection;
    }
    if (!selection.isComplete && TickerMode.valuesOf(context).enabled) {
      _scheduleCoverScan(selection);
    }
    Future<String?> coverFuture(MusicTrack track) => _coverFutures.putIfAbsent(
      track.path,
      () => ref
          .read(libraryCoverUiControllerProvider)
          .deferredPlaybackCover(track, context: context),
    );
    final tracks = queue.expandedTracks;
    final activeColor = cardState.queueColorValue == null
        ? cs.primary
        : Color(cardState.queueColorValue!);
    final revealActionColor = cardState.queueColorValue == null
        ? cs.primary
        : activeColor;
    final isPlaying = cardState.isPlaying;
    final coverSelection = selection;
    for (final probe in coverSelection.probes) {
      final track = probe.track;
      if (_coverFutures.containsKey(track.path)) continue;
      final future = coverFuture(track);
      if (coverSelection.selected.contains(probe)) continue;
      unawaited(
        future.then<void>((path) {
          if (path == null || path.isEmpty) return;
          // A cold standalone track can become eligible once its embedded art
          // is found. Add it in queue order without repeating the candidate scan.
          scheduleMicrotask(() {
            if (coverSelection.addDiscoveredTrack(track.path) &&
                mounted &&
                identical(_coverSelection, coverSelection)) {
              setState(() {});
            }
          });
        }),
      );
    }
    final coverItems = coverSelection.selected
        .map(
          (entry) => (
            track: entry.track,
            coverPath: library.resolvedPlaybackCoverPathForTrack(entry.track),
            future: coverFuture(entry.track),
          ),
        )
        .toList(growable: false);
    final resolvedCurrentPath = playback.resolveRetargetedPath(
      cardState.trackPath,
    );
    final originalCurrentPath =
        playback.originalPathForRetargeted(cardState.trackPath) ??
        playback.originalPathForRetargeted(resolvedCurrentPath);
    int currentIndex = -1;
    final hintIndex = queueState.currentIndex;
    if (hintIndex >= 0 && hintIndex < tracks.length) {
      final hintTrack = tracks[hintIndex];
      if (PathMatcher.equalsNormalized(hintTrack.path, cardState.trackPath) ||
          PathMatcher.equalsNormalized(hintTrack.path, resolvedCurrentPath) ||
          (originalCurrentPath != null &&
              PathMatcher.equalsNormalized(
                hintTrack.path,
                originalCurrentPath,
              ))) {
        currentIndex = hintIndex;
      }
    }
    if (currentIndex < 0) {
      final matchedCurrentIndex = tracks.indexWhere(
        (track) =>
            PathMatcher.equalsNormalized(track.path, cardState.trackPath) ||
            PathMatcher.equalsNormalized(track.path, resolvedCurrentPath) ||
            (originalCurrentPath != null &&
                PathMatcher.equalsNormalized(track.path, originalCurrentPath)),
      );
      currentIndex = matchedCurrentIndex >= 0
          ? matchedCurrentIndex
          : (hintIndex >= 0 && hintIndex < tracks.length ? hintIndex : -1);
    }
    final currentTrack = currentIndex >= 0
        ? tracks[currentIndex]
        : ref
              .read(audioPathCoordinatorProvider)
              .sessionTrackForPath(session.id, cardState.trackPath);
    final currentCoverScope = currentTrack == null
        ? null
        : library.coverArtworkCacheService.coverSearchKeyForTrack(currentTrack);
    final currentCoverIndex = coverItems.indexWhere(
      (item) =>
          currentTrack != null &&
          (PathMatcher.equalsNormalized(item.track.path, currentTrack.path) ||
              (currentCoverScope != null &&
                  library.coverArtworkCacheService.coverSearchKeyForTrack(
                        item.track,
                      ) ==
                      currentCoverScope)),
    );
    final currentTrackName = tracks.isEmpty
        ? i18n.tr('empty_playback_queue')
        : currentTrack?.displayName ??
              path.basenameWithoutExtension(cardState.trackPath);
    final featureIconColor = cardState.queueColorValue != null
        ? activeColor
        : cs.primary;
    return UndoableRemovalTransition(
      hidden: isHidden,
      child: SwipeRevealCard(
        key: ValueKey(session.id),
        shape: playlistRowShape,
        color: revealActionColor,
        closedColor: cs.surface,
        enabled: !isSelectionMode,
        destructive: false,
        primaryActionIcon: Icons.edit_rounded,
        actionLabel: i18n.tr('edit'),
        removeTooltip: i18n.tr('edit_playback_queue'),
        onRemove: onEdit,
        closeAfterPrimaryAction: true,
        onLeadingAction: onTogglePin,
        onSelectMultiple: onLongPress,
        selectMultipleLabel: i18n.tr('select_multiple'),
        animateLeadingActionClose: true,
        leadingActionLabel: i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top'),
        leadingActionTooltip: i18n.tr(
          isPinned ? 'unpin_from_top' : 'pin_to_top',
        ),
        leadingActionIcon: Icons.push_pin_rounded,
        leadingActionIconWidget: isPinned ? const PushPinOffIcon() : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: playlistRowHeight),
          child: Material(
            key: ValueKey('playback_queue_row_surface_${session.id}'),
            color: isSelected
                ? cs.primaryContainer.withValues(alpha: 0.15)
                : Colors.transparent,
            child: AppEntryInkWell(
              navigationEntry: !isSelectionMode,
              excludeFromSemantics: true,
              onTap: () {
                if (isSelectionMode) {
                  onToggleSelect?.call();
                } else {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.tap,
                  );
                  onOpen(context);
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
                key: ValueKey<String>(
                  'playback_queue_card_content_${session.id}',
                ),
                padding: playlistRowPadding,
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SessionCoverProgressRing(
                          session: session,
                          sessionId: session.id,
                          activeColor: activeColor,
                          size: playlistCoverSize,
                          child: _QueueCoverGrid(
                            items: coverItems,
                            sessionId: session.id,
                            currentCoverIndex: currentCoverIndex,
                            coverCacheWidth: coverCacheWidth,
                            dimension: coverProgressInnerDimension(
                              playlistCoverSize,
                            ),
                          ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: PlaylistSelectionIndicator(
                            sessionId: session.id,
                            isSelected: isSelected,
                          ),
                        ),
                        Positioned(
                          top: -2,
                          right: -2,
                          child: PlaylistPinnedIndicator(
                            isPinned: isPinned,
                            sessionId: session.id,
                            color: activeColor,
                            isSelected: isSelected,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: isSelectionMode ? isSelected : null,
                        label: i18n.tr('open_playback_details'),
                        onTap: isSelectionMode
                            ? onToggleSelect
                            : () => onOpen(context),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              queue.name,
                              key: ValueKey<String>(
                                'playback_queue_name_${session.id}',
                              ),
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
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (isPlaying)
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: PlayingSoundWaveIndicator(
                                          key: ValueKey<String>(
                                            'playback_queue_sound_wave_${session.id}',
                                          ),
                                          color: activeColor,
                                          isPlaying: isPlaying,
                                        ),
                                      ),
                                    ),
                                  TextSpan(text: currentTrackName),
                                ],
                              ),
                              key: ValueKey<String>(
                                'playback_queue_track_0_${session.id}',
                              ),
                              semanticsLabel: currentTrackName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    height: 1.12,
                                    color: isPlaying ? activeColor : null,
                                  ),
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
                              color: featureIconColor,
                              child: IconButton(
                                tooltip: cardState.isPlaying
                                    ? i18n.tr('pause')
                                    : i18n.tr('play'),
                                onPressed: tracks.isEmpty
                                    ? null
                                    : () {
                                        AppInteractionFeedback.trigger(
                                          AppInteractionFeedbackType.selection,
                                        );
                                        playback.toggleSessionPlayPause(
                                          session.id,
                                        );
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
                                  switchOutCurve: kAppFadeCurve,
                                  switchInCurve: kAppFadeCurve,
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : kAppFadeDuration,
                                  transitionBuilder: (child, animation) {
                                    return ScaleTransition(
                                      scale: Tween<double>(begin: 0.4, end: 1.0)
                                          .animate(
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
                            if (cardState.playbackError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.error_outline_rounded,
                                  size: 14,
                                  color: cs.error,
                                ),
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
    );
  }
}

class _QueueCoverSelection {
  _QueueCoverSelection(this.entries, this.library, this.generation);

  final List<PlaybackQueueEntry> entries;
  final LibraryFacade library;
  final int generation;
  final probes = <({int index, MusicTrack track})>[];
  final selected = <({int index, MusicTrack track})>[];
  int _nextEntry = 0;

  bool get isComplete =>
      _nextEntry == entries.length ||
      (probes.length == 4 && selected.length == 4);

  bool scan() {
    var changed = false;
    // Missing artwork may force a search through the full queue. Bound each
    // frame's share and retain the cursor across scroll-driven remounts.
    final end = math.min(_nextEntry + 32, entries.length);
    while (_nextEntry < end && !isComplete) {
      final index = _nextEntry++;
      final tracks = entries[index].tracks;
      if (tracks.isEmpty) continue;
      final track = tracks.first;
      final candidate = (index: index, track: track);
      if (probes.length < 4) {
        probes.add(candidate);
        changed = true;
      }
      if (selected.length < 4 &&
          shouldShowPlaylistCoverArtwork(
            track,
            library.resolvedPlaybackCoverPathForTrack(track),
          )) {
        selected.add(candidate);
        changed = true;
      }
    }
    return changed;
  }

  bool addDiscoveredTrack(String path) {
    var changed = false;
    for (final probe in probes) {
      if (probe.track.path != path || selected.contains(probe)) continue;
      if (selected.length == 4 && probe.index > selected.last.index) continue;
      selected.add(probe);
      selected.sort((left, right) => left.index.compareTo(right.index));
      if (selected.length > 4) selected.removeLast();
      changed = true;
    }
    return changed;
  }
}

class _QueueCoverGrid extends StatelessWidget {
  const _QueueCoverGrid({
    required this.items,
    required this.sessionId,
    required this.currentCoverIndex,
    required this.coverCacheWidth,
    this.dimension = playlistCoverSize,
  });

  final List<({MusicTrack track, String? coverPath, Future<String?> future})>
  items;
  final String sessionId;
  final int currentCoverIndex;
  final int? coverCacheWidth;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final content = items.isEmpty
        ? const CoverFallbackArtwork()
        : items.length == 1
        ? _buildCell(0)
        : Stack(
            fit: StackFit.expand,
            children: [
              for (var index = 0; index < items.length; index++)
                _buildSector(index),
              IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('playback_queue_cover_dividers'),
                  painter: _QueueCoverDividerPainter(count: items.length),
                ),
              ),
            ],
          );
    return SessionCoverAnchor(
      sessionId: sessionId,
      radius: dimension / 2,
      location: SessionCoverLocation.playlist,
      imageKey: ValueKey('playback_queue_cover_cell_$currentCoverIndex'),
      child: CoverArtworkFrame(
        key: const ValueKey('playback_queue_cover_grid'),
        borderRadius: BorderRadius.circular(dimension / 2),
        child: SizedBox.square(dimension: dimension, child: content),
      ),
    );
  }

  Widget _buildSector(int index) {
    final sector = _QueueCoverSectorClipper(items.length, index);
    return ClipPath(
      clipper: sector,
      child: Transform.translate(
        offset: sector.imageCenterOffset(Size.square(dimension)),
        child: _buildCell(index),
      ),
    );
  }

  Widget _buildCell(int index) {
    final item = items[index];
    return SizedBox.expand(
      key: ValueKey('playback_queue_cover_cell_$index'),
      child: QueueTrackCover(
        key: ValueKey('$index:${item.track.path}'),
        track: item.track,
        coverPath: item.coverPath,
        coverCacheWidth: coverCacheWidth,
        future: item.future,
      ),
    );
  }
}

class _QueueCoverSectorClipper extends CustomClipper<Path> {
  const _QueueCoverSectorClipper(this.count, this.index);

  final int count;
  final int index;

  double get _sweepAngle => 2 * math.pi / count;

  static double startAngle(int count, int index) {
    final sweepAngle = 2 * math.pi / count;
    return switch (count) {
      2 => index == 0 ? math.pi / 2 : -math.pi / 2,
      3 => -5 * math.pi / 6 + index * sweepAngle,
      4 => switch (index) {
        0 => math.pi,
        1 => -math.pi / 2,
        2 => math.pi / 2,
        _ => 0,
      },
      _ => throw StateError('Queue cover count must be between 2 and 4'),
    };
  }

  double get _startAngle => startAngle(count, index);

  Offset imageCenterOffset(Size size) {
    final sweep = _sweepAngle;
    final centroidDistance =
        4 * (size.shortestSide / 2) * math.sin(sweep / 2) / (3 * sweep);
    final bisector = _startAngle + sweep / 2;
    return Offset(
      centroidDistance * math.cos(bisector),
      centroidDistance * math.sin(bisector),
    );
  }

  @override
  Path getClip(Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    return Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        _startAngle,
        _sweepAngle,
        false,
      )
      ..close();
  }

  @override
  bool shouldReclip(_QueueCoverSectorClipper oldClipper) =>
      count != oldClipper.count || index != oldClipper.index;
}

class _QueueCoverDividerPainter extends CustomPainter {
  const _QueueCoverDividerPainter({required this.count});

  static const Color _highlightColor = Color(0x60FFFFFF);
  static const double _strokeWidth = 1.0;

  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    if (count < 2) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..color = _highlightColor
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (var index = 0; index < count; index++) {
      final angle = _QueueCoverSectorClipper.startAngle(count, index);
      final target =
          center + Offset(radius * math.cos(angle), radius * math.sin(angle));
      canvas.drawLine(center, target, paint);
    }
  }

  @override
  bool shouldRepaint(_QueueCoverDividerPainter oldDelegate) =>
      count != oldDelegate.count;
}
