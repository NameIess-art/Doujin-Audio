import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_buttons.dart';
import 'package:path/path.dart' as path;

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../core/logging/app_log_service.dart';
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
    required this.sessionId,
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

  final String sessionId;
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
  late final _coverDiscoverKey =
      'queue_cover_discover:${identityHashCode(this)}';
  final List<String> _pendingDiscoveredPaths = [];
  _QueueCoverSelection? _coverSelection;
  PlaybackQueueDefinition? _requestedPreviewQueue;
  ValueListenable<TickerModeData>? _tickerMode;
  bool _coverRefreshPending = false;

  bool get _coverActivityEnabled => _tickerMode?.value.enabled ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerMode = TickerMode.getValuesNotifier(context);
    if (identical(tickerMode, _tickerMode)) return;
    _tickerMode?.removeListener(_resumeCoverWork);
    _tickerMode = tickerMode;
    tickerMode.addListener(_resumeCoverWork);
  }

  void _resumeCoverWork() {
    if (_coverActivityEnabled) {
      UiInteractionCoordinator.instance.scheduleCommitFrame();
    }
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_resumeCoverWork);
    _pendingDiscoveredPaths.clear();
    UiInteractionCoordinator.instance.cancelCommit(_coverScanKey);
    UiInteractionCoordinator.instance.cancelCommit(_coverDiscoverKey);
    super.dispose();
  }

  void _scheduleCoverRefresh() {
    _coverRefreshPending = true;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _coverScanKey,
      structural: true,
      canRun: () => mounted && _coverActivityEnabled,
      commit: () => setState(() => _coverRefreshPending = false),
    );
  }

  void _scheduleCoverScan(_QueueCoverSelection selection) {
    if (_coverRefreshPending || selection.isComplete) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _coverScanKey,
      structural: true,
      canRun: () =>
          mounted &&
          identical(_coverSelection, selection) &&
          _coverActivityEnabled,
      commit: () {
        if (selection.scan()) setState(() {});
        _scheduleCoverScan(selection);
      },
    );
  }

  static int _coverRevisionForTracks(
    LibraryFacade library,
    int count,
    MusicTrack? Function(int) trackAt,
  ) {
    final cache = library.coverArtworkCacheService;
    var hash = cache.revisionForScope('').epoch;
    for (var i = 0; i < count; i++) {
      final track = trackAt(i);
      if (track == null) continue;
      final scope = cache.coverSearchKeyForTrack(track) ?? track.path;
      final scopeRev = cache.revisionForScope(scope);
      hash = Object.hash(hash, scopeRev.epoch, scopeRev.revision);
      final folderScope = cache.coverScopeFolderForTrack(track);
      if (folderScope != null) {
        final folderRev = cache.revisionForScope(folderScope);
        hash = Object.hash(hash, folderRev.epoch, folderRev.revision);
      }
    }
    return hash;
  }

  Future<void> _loadCoverPreviews(
    PlaybackQueueDefinition queue,
  ) async {
    final sessionId = widget.sessionId;
    try {
      final previews = await widget.playback.loadQueueEntryPreviews(
        sessionId,
        start: 0,
        limit: 4,
      );
      if (!mounted ||
          widget.sessionId != sessionId ||
          !identical(
            widget.playback.sessionById(sessionId)?.playbackQueue,
            queue,
          )) {
        return;
      }
      MusicTrack? trackAt(int index) => previews[index].firstTrack;
      final generation = _coverRevisionForTracks(
        widget.library,
        previews.length,
        trackAt,
      );
      final selection = _QueueCoverSelection(
        previews.length,
        trackAt,
        widget.library,
        generation,
      );
      _coverSelections[queue] = selection;
      _scheduleCoverRefresh();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'playback_queue_cover_previews_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final library = widget.library;
    final playback = widget.playback;
    final coverCacheWidth = widget.coverCacheWidth;
    final onOpen = widget.onOpen;
    final onEdit = widget.onEdit;
    final showSubtitles = ref.watch(
      subtitleSettingsProvider.select(
        (settings) => settings.isGlobalEnabled(sessionId),
      ),
    );
    final isSelectionMode = widget.isSelectionMode;
    final isSelected = widget.isSelected;
    final isPinned = widget.isPinned;
    final onLongPress = widget.onLongPress;
    final onToggleSelect = widget.onToggleSelect;
    final onTogglePin = widget.onTogglePin;
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(playbackSessionRemovalKey(sessionId)),
    );
    final cardState = ref.watch(playlistSessionCardStateProvider(sessionId));
    final queueState = ref.watch(
      playbackSessionProvider(sessionId).select(
        (session) => (
          queue: session?.playbackQueue,
          currentIndex: session?.currentQueueIndex ?? -1,
          requiresLoad: session?.queueLoadingRequired ?? false,
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
    final coverKey = queueState.requiresLoad ? queue : queue.entries;
    var selection = _coverSelections[coverKey];
    final coverGeneration = ref.watch(
      coverGenerationProvider.select((_) {
        if (queueState.requiresLoad) {
          return selection == null
              ? library.coverArtworkCacheService.revisionForScope('').epoch
              : _coverRevisionForTracks(
                  library,
                  selection.entryCount,
                  selection.trackAt,
                );
        }
        final limit = selection != null && selection.selected.length == 4
            ? math.min(selection.selected.last.index + 1, queue.entries.length)
            : queue.entries.length;
        return _coverRevisionForTracks(
          library,
          limit,
          (index) => queue.entries[index].tracks.firstOrNull,
        );
      }),
    );
    final coordinator = UiInteractionCoordinator.instance;
    final tickerEnabled = _coverActivityEnabled;
    final isDeferred = coordinator.isVisualUpdateDeferred;
    final hasFreshSelection =
        selection != null &&
        identical(selection.library, library) &&
        selection.generation == coverGeneration;
    if (!hasFreshSelection) {
      if (isDeferred || !tickerEnabled) {
        _scheduleCoverRefresh();
        selection =
            _coverSelection != null &&
                identical(_coverSelection!.library, library) &&
                _coverSelection!.generation == coverGeneration
            ? _coverSelection
            : null;
      } else if (!queueState.requiresLoad) {
        selection = _QueueCoverSelection(
          queue.entries.length,
          (index) => queue.entries[index].tracks.firstOrNull,
          library,
          coverGeneration,
        );
        selection.scan();
        _coverSelections[coverKey] = selection;
      } else if (selection != null) {
        selection = _QueueCoverSelection(
          selection.entryCount,
          selection.trackAt,
          library,
          coverGeneration,
        );
        selection.scan();
        _coverSelections[coverKey] = selection;
      } else if (!identical(_requestedPreviewQueue, queue) &&
          queue.entryCount > 0) {
        _requestedPreviewQueue = queue;
        unawaited(_loadCoverPreviews(queue));
      }
    }
    if (!identical(_coverSelection, selection)) {
      _coverFutures.clear();
      _pendingDiscoveredPaths.clear();
      _coverSelection = selection;
    }
    if (selection != null && !selection.isComplete) {
      _scheduleCoverScan(selection);
    }
    Future<String?> coverFuture(MusicTrack track) => _coverFutures.putIfAbsent(
      track.path,
      () => ref
          .read(libraryCoverUiControllerProvider)
          .deferredPlaybackCover(track, context: context),
    );
    final hasTracks = queue.hasTracks;
    final activeColor = cardState.queueColorValue == null
        ? cs.primary
        : Color(cardState.queueColorValue!);
    final isPlaying = cardState.isPlaying;
    final coverSelection = selection;
    if (coverSelection != null &&
        (isDeferred || !tickerEnabled) &&
        coverSelection.probes.any(
          (probe) => !_coverFutures.containsKey(probe.track.path),
        )) {
      _scheduleCoverRefresh();
    }
    if (coverSelection != null && !isDeferred && tickerEnabled) {
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
            void applyDiscoveredCover() {
              if (!mounted || !identical(_coverSelection, coverSelection)) {
                return;
              }
              if (UiInteractionCoordinator.instance.isVisualUpdateDeferred) {
                _pendingDiscoveredPaths.add(track.path);
                UiInteractionCoordinator.instance.scheduleCommit(
                  key: _coverDiscoverKey,
                  structural: true,
                  canRun: () =>
                      mounted &&
                      identical(_coverSelection, coverSelection) &&
                      _coverActivityEnabled,
                  commit: () {
                    if (_pendingDiscoveredPaths.isEmpty) return;
                    var changed = false;
                    for (final discovered in _pendingDiscoveredPaths) {
                      if (coverSelection.addDiscoveredTrack(discovered)) {
                        changed = true;
                      }
                    }
                    _pendingDiscoveredPaths.clear();
                    if (changed) setState(() {});
                  },
                );
                return;
              }
              if (coverSelection.addDiscoveredTrack(track.path)) {
                setState(() {});
              }
            }

            scheduleMicrotask(applyDiscoveredCover);
          }),
        );
      }
    }
    final coverItems = coverSelection == null
        ? const <
            ({MusicTrack track, String? coverPath, Future<String?> future})
          >[]
        : coverSelection.selected
              .map(
                (entry) => (
                  track: entry.track,
                  coverPath: library.resolvedPlaybackCoverPathForTrack(
                    entry.track,
                  ),
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
    final hintIndex = queueState.currentIndex;
    final runtimeTracks = playback.sessionById(sessionId)?.customQueueTracks;
    final hintTrack = queueState.requiresLoad || hintIndex < 0
        ? null
        : runtimeTracks != null && hintIndex < runtimeTracks.length
        ? runtimeTracks[hintIndex]
        : queue.trackAt(hintIndex);
    final matchesHint =
        hintTrack != null &&
        (PathMatcher.equalsNormalized(hintTrack.path, cardState.trackPath) ||
            PathMatcher.equalsNormalized(hintTrack.path, resolvedCurrentPath) ||
            (originalCurrentPath != null &&
                PathMatcher.equalsNormalized(
                  hintTrack.path,
                  originalCurrentPath,
                )));
    final currentTrack = matchesHint
        ? hintTrack
        : ref
                  .read(audioPathCoordinatorProvider)
                  .sessionTrackForPath(sessionId, cardState.trackPath) ??
              hintTrack;
    final currentCoverScope = currentTrack == null
        ? null
        : library.coverArtworkCacheService.coverSearchKeyForTrack(currentTrack);
    var currentCoverIndex = coverItems.indexWhere(
      (item) =>
          currentTrack != null &&
          (PathMatcher.equalsNormalized(item.track.path, currentTrack.path) ||
              (currentCoverScope != null &&
                  library.coverArtworkCacheService.coverSearchKeyForTrack(
                        item.track,
                      ) ==
                      currentCoverScope)),
    );
    if (currentCoverIndex == -1 &&
        currentTrack != null &&
        coverItems.any((item) => item.coverPath != null)) {
      // A later track can share the first track's artwork even when their
      // cover lookup keys are different.
      final currentArtwork = library.resolvedPlaybackCoverPathForTrack(
        currentTrack,
      );
      if (currentArtwork != null) {
        currentCoverIndex = coverItems.indexWhere((item) {
          final coverPath = item.coverPath;
          return coverPath != null &&
              PathMatcher.equalsNormalized(coverPath, currentArtwork);
        });
      }
    }
    final currentTrackName = !hasTracks
        ? i18n.tr('empty_playback_queue')
        : currentTrack?.displayName ??
              path.basenameWithoutExtension(cardState.trackPath);
    final featureIconColor = cardState.queueColorValue != null
        ? activeColor
        : cs.primary;
    final labelsContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          queue.name,
          key: ValueKey<String>('playback_queue_name_$sessionId'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: activeColor,
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
                    padding: const EdgeInsets.only(right: 6),
                    child: PlayingSoundWaveIndicator(
                      key: ValueKey<String>(
                        'playback_queue_sound_wave_$sessionId',
                      ),
                      color: activeColor,
                      isPlaying: isPlaying,
                    ),
                  ),
                ),
              TextSpan(text: currentTrackName),
            ],
          ),
          key: ValueKey<String>('playback_queue_track_0_$sessionId'),
          semanticsLabel: currentTrackName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 14,
            height: 1.12,
            color: isPlaying ? activeColor : null,
          ),
        ),
      ],
    );
    final cardBody = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: playlistRowHeight),
      child: Material(
        key: ValueKey('playback_queue_row_surface_$sessionId'),
        shape: playlistRowShape,
        color: Colors.transparent,
        child: AppEntryInkWell(
          customBorder: playlistRowShape,
          excludeFromSemantics: true,
          onTap: () {
            final selectionActive =
                PlaylistSelectionScope.maybeReadIsSelectionMode(context) ??
                isSelectionMode;
            if (selectionActive) {
              onToggleSelect?.call();
            } else {
              onOpen(context);
            }
          },
          onLongPress: onLongPress,
          child: PlaylistAudioRow(
            contentKey: ValueKey<String>(
              'playback_queue_card_content_$sessionId',
            ),
            cover: Stack(
              clipBehavior: Clip.none,
              children: [
                SessionCoverProgressRing(
                  sessionId: sessionId,
                  activeColor: activeColor,
                  size: playlistCoverSize,
                  child: _QueueCoverGrid(
                    items: coverItems,
                    sessionId: sessionId,
                    currentCoverIndex: currentCoverIndex,
                    coverCacheWidth: coverCacheWidth,
                    dimension: coverProgressInnerDimension(playlistCoverSize),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Builder(
                    builder: (badgeContext) => PlaylistSelectionIndicator(
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
                  child: Builder(
                    builder: (badgeContext) => PlaylistPinnedIndicator(
                      isPinned:
                          PlaylistPinnedScope.maybeIsPinnedOf(
                            badgeContext,
                            sessionId,
                          ) ??
                          isPinned,
                      sessionId: sessionId,
                    ),
                  ),
                ),
              ],
            ),
            labels: Builder(
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
            actions: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SessionFeatureBadgeStack(
                      featureIcons: sessionFeatureBadgeIcons(
                        showSubtitles: showSubtitles,
                        channelSwapEnabled: cardState.channelSwapEnabled,
                        audioEffects: cardState.audioEffects,
                        speed: cardState.speed,
                      ),
                      color: featureIconColor,
                      child: IconButton(
                        tooltip: i18n.tr(
                          cardState.playbackError != null
                              ? 'retry_playback'
                              : cardState.isPlaying
                              ? 'pause'
                              : 'play',
                        ),
                        onPressed: !hasTracks && !isPlaying
                            ? null
                            : () {
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
                          child: cardState.playbackError != null
                              ? const Icon(
                                  Icons.refresh_rounded,
                                  key: ValueKey('retry'),
                                  size: 28,
                                )
                              : cardState.isLoading
                              ? const SizedBox(
                                  key: ValueKey('loading'),
                                  width: 22,
                                  height: 22,
                                  child: RepaintBoundary(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.3,
                                    ),
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
          ),
        ),
      ),
    );
    return UndoableRemovalTransition(
      hidden: isHidden,
      child: Builder(
        builder: (swipeContext) {
          final selectionMode =
              PlaylistSelectionScope.maybeIsSelectionModeOf(swipeContext) ??
              isSelectionMode;
          final pinned =
              PlaylistPinnedScope.maybeIsPinnedOf(swipeContext, sessionId) ??
              isPinned;
          return SwipeRevealCard(
            key: ValueKey(sessionId),
            shape: playlistRowShape,
            swipeEnabled: !selectionMode,
            leadingSwipeEnabled: false,
            color: activeColor,
            closedColor: cs.surface,
            enabled: !selectionMode,
            destructive: false,
            primaryActionIcon: Icons.edit_rounded,
            actionLabel: i18n.tr('edit'),
            removeTooltip: i18n.tr('edit_playback_queue'),
            onRemove: onEdit,
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
            leadingActionIconWidget: pinned ? const PushPinOffIcon() : null,
            child: cardBody,
          );
        },
      ),
    );
  }
}

class _QueueCoverSelection {
  _QueueCoverSelection(
    this.entryCount,
    this.trackAt,
    this.library,
    this.generation,
  );

  final int entryCount;
  final MusicTrack? Function(int) trackAt;
  final LibraryFacade library;
  final int generation;
  final probes = <({int index, MusicTrack track})>[];
  final selected = <({int index, MusicTrack track})>[];
  int _nextEntry = 0;

  bool get isComplete =>
      _nextEntry == entryCount || (probes.length == 4 && selected.length == 4);

  bool scan() {
    var changed = false;
    // Missing artwork may force a search through the full queue. Bound each
    // frame's share and retain the cursor across scroll-driven remounts.
    final end = math.min(_nextEntry + 32, entryCount);
    while (_nextEntry < end && !isComplete) {
      final index = _nextEntry++;
      final track = trackAt(index);
      if (track == null) continue;
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
