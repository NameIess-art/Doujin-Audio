import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/application/audio_path_coordinator.dart';
import '../../../app/application/audio_ui_warmup_coordinator.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/state/subtitle_settings_provider.dart';
import '../application/playback_facade.dart';
import '../../settings/application/settings_state.dart';
import '../application/playback_session.dart';
import '../application/subtitle_overlay_controller.dart';
import '../application/playback_time_segment_service.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/platform/permission_action_controller.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/content_bound_reorder_area.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import 'playback_position_ui_gate.dart';
import 'playback_error_text.dart';
import '../../../core/widgets/reorder_auto_scroller.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/shimmer_loading.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/target_countdown_builder.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/unified_dropdown.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../asmr/domain/asmr_models.dart';
import '../../library/presentation/audio_detail_sheet.dart';
import '../../library/application/library_facade.dart';
import '../../settings/application/settings_command_controller.dart';
import '../../asmr/presentation/asmr_work_detail_sheet.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import '../domain/time_segment_label.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';

part 'playlist_tab_list.dart';
part 'playlist_tab_detail.dart';
part 'playlist_tab_detail_content.dart';
part 'playlist_tab_media.dart';
part 'playlist_tab_loop.dart';
part 'playlist_tab_progress.dart';
part 'playlist_tab_transport_controls.dart';
part 'playlist_tab_time_segments.dart';
part 'playlist_tab_audio_features.dart';
part 'playlist_tab_speed_controls.dart';
part 'playlist_tab_volume_timer.dart';
part 'playlist_tab_queue.dart';

// Four 48px Material tap targets plus the loop capsule padding and gaps.
const double _sessionDetailCapsuleWidth = 52;
const double _sessionDetailCapsuleHeight = 212;
const double _sessionDetailCapsuleAnchorOffsetY = 26;

enum _SessionDetailForegroundLevel { strong, medium, muted }

Color _sessionDetailForeground(
  ColorScheme colorScheme,
  _SessionDetailForegroundLevel level, {
  Color? darkFallback,
}) {
  if (colorScheme.brightness == Brightness.dark) {
    return darkFallback ?? colorScheme.onSurface;
  }

  return switch (level) {
    _SessionDetailForegroundLevel.strong => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.10),
      colorScheme.onSurface,
    ),
    _SessionDetailForegroundLevel.medium => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.06),
      colorScheme.onSurfaceVariant,
    ),
    _SessionDetailForegroundLevel.muted => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.03),
      colorScheme.onSurfaceVariant,
    ).withValues(alpha: 0.72),
  };
}

List<MusicTrack> orderTracksForSessionSwitcher(
  List<MusicTrack> tracks, {
  required bool preserveQueueOrder,
}) {
  if (preserveQueueOrder ||
      tracks.length < 2 ||
      !tracks.every((track) => track.remoteMetadataKind == 'asmr.one')) {
    return tracks;
  }
  final sorted = List<MusicTrack>.of(tracks);
  sorted.sort((left, right) {
    final leftPath = left.remoteMetadata?['trackRelativePath']?.toString();
    final rightPath = right.remoteMetadata?['trackRelativePath']?.toString();
    final pathResult = compareNatural(
      leftPath?.trim().isNotEmpty == true ? leftPath!.trim() : left.displayName,
      rightPath?.trim().isNotEmpty == true
          ? rightPath!.trim()
          : right.displayName,
    );
    if (pathResult != 0) return pathResult;
    return compareNatural(left.path, right.path, caseSensitive: true);
  });
  return List<MusicTrack>.unmodifiable(sorted);
}

List<IconData> sessionFeatureBadgeIcons({
  required bool showSubtitles,
  required bool channelSwapEnabled,
  required AudioEffectsState audioEffects,
  required double speed,
}) {
  return <IconData>[
    if (showSubtitles) Icons.subtitles_rounded,
    if ((speed - 1.0).abs() >= 0.001) Icons.speed_rounded,
    if (audioEffects.eqEnabled) Icons.tune_rounded,
    if (audioEffects.skipSilenceEnabled)
      Icons.keyboard_double_arrow_right_rounded,
    if (audioEffects.noiseReductionEnabled) Icons.graphic_eq_rounded,
    if (audioEffects.volumeNormalizationEnabled)
      Icons.vertical_align_center_rounded,
    if (audioEffects.panning.abs() >= 0.001) Icons.compare_arrows_rounded,
    if (channelSwapEnabled) Icons.swap_horiz_rounded,
  ];
}

({List<IconData> top, List<IconData> bottom}) splitSessionFeatureBadgeIcons(
  List<IconData> icons, {
  int bottomLimit = 4,
}) {
  return (
    top: icons.skip(bottomLimit).toList(growable: false),
    bottom: icons.take(bottomLimit).toList(growable: false),
  );
}

class SessionFeatureIconRow extends StatelessWidget {
  const SessionFeatureIconRow({
    super.key,
    required this.featureIcons,
    required this.color,
    this.iconSize = 10,
    this.spacing = 2,
    this.runSpacing = 1,
    this.maxWidth,
    this.alignment = WrapAlignment.center,
  });

  final List<IconData> featureIcons;
  final Color color;
  final double iconSize;
  final double spacing;
  final double runSpacing;
  final double? maxWidth;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (featureIcons.isEmpty) {
      return const SizedBox.shrink();
    }
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < featureIcons.length; index++) ...[
          if (index > 0) SizedBox(width: spacing),
          Icon(featureIcons[index], size: iconSize, color: color),
        ],
      ],
    );
    if (maxWidth == null) return row;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth!),
      child: Align(alignment: _featureIconAlignment(alignment), child: row),
    );
  }
}

Alignment _featureIconAlignment(WrapAlignment alignment) {
  return switch (alignment) {
    WrapAlignment.start => Alignment.centerLeft,
    WrapAlignment.end => Alignment.centerRight,
    _ => Alignment.center,
  };
}

class SessionFeatureBadgeStack extends StatelessWidget {
  const SessionFeatureBadgeStack({
    super.key,
    required this.featureIcons,
    required this.color,
    required this.child,
    this.width = 56,
    this.height = 64,
  });

  final List<IconData> featureIcons;
  final Color color;
  final Widget child;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final rows = splitSessionFeatureBadgeIcons(featureIcons);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            child: SessionFeatureIconRow(
              featureIcons: rows.top,
              color: color,
              maxWidth: width,
            ),
          ),
          Center(child: child),
          Positioned(
            bottom: 0,
            child: SessionFeatureIconRow(
              featureIcons: rows.bottom,
              color: color,
              maxWidth: width,
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _coverFutureForTrack(
  LibraryFacade library,
  MusicTrack? track, {
  bool cachedOnly = false,
}) {
  if (track == null) {
    return Future<String?>.value();
  }
  if (cachedOnly) {
    return SynchronousFuture<String?>(
      library.resolvedPlaybackCoverPathForTrack(track),
    );
  }
  return library.playbackCoverPathFutureForTrack(track);
}

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return _SessionDetailRoute(sessionId: sessionId);
}

class _SessionDetailRoute extends PageRoute<void> {
  _SessionDetailRoute({required this.sessionId}) {
    _revealBehindNotifier.addListener(_handleRevealBehindChanged);
  }

  final String sessionId;
  final ValueNotifier<bool> _revealBehindNotifier = ValueNotifier<bool>(false);

  void _handleRevealBehindChanged() {
    if (overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = opaque;
    }
    changedInternalState();
  }

  @override
  bool get opaque => !_revealBehindNotifier.value;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return SessionDetailPage(
      sessionId: sessionId,
      revealBehindNotifier: _revealBehindNotifier,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }

  @override
  void dispose() {
    _revealBehindNotifier.removeListener(_handleRevealBehindChanged);
    _revealBehindNotifier.dispose();
    super.dispose();
  }
}

class PlaylistTab extends ConsumerStatefulWidget {
  const PlaylistTab({
    super.key,
    this.onTimerTap,
    this.onOpenLibrary,
    this.activeTabIndexListenable,
  });

  final VoidCallback? onTimerTap;
  final VoidCallback? onOpenLibrary;
  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends ConsumerState<PlaylistTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<PlaylistTab> {
  final ScrollController _scrollController = ScrollController();
  bool _isReordering = false;
  bool _initialPlaceholderDismissed = false;
  bool _initialPlaceholderDismissScheduled = false;
  PlaylistListState? _reorderSnapshot;
  String? _lastPlaybackCoverWarmupSignature;

  @override
  int get tabIndex => 2;

  @override
  ScrollController get mainScrollController => _scrollController;

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == tabIndex;

  void _handleActiveTabChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleInitialPlaceholderDismissal({required bool isInitialized}) {
    if (_initialPlaceholderDismissed ||
        _initialPlaceholderDismissScheduled ||
        !_isActive ||
        !isInitialized) {
      return;
    }
    _initialPlaceholderDismissScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPlaceholderDismissScheduled = false;
      if (!mounted || _initialPlaceholderDismissed || !_isActive) return;
      setState(() => _initialPlaceholderDismissed = true);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
  }

  void _schedulePlaybackCoverWarmup(
    PlaylistStructureState structureState,
    AudioPathCoordinator paths,
    AudioUiWarmupCoordinator warmup,
  ) {
    if (_isReordering ||
        !structureState.isInitialized ||
        !structureState.hasSessions) {
      return;
    }
    final tracks = <MusicTrack?>[];
    final signatureParts = <String>[
      structureState.coverGeneration.toString(),
      structureState.entries.length.toString(),
    ];
    for (final structure in structureState.entries.take(10)) {
      final session = structure.session;
      signatureParts.add(structure.sessionId);
      if (structure.isPlaybackQueue) {
        for (final entry in session.playbackQueue!.entries.take(4)) {
          final track = entry.tracks.firstOrNull;
          if (track == null) continue;
          signatureParts.add(track.path);
          tracks.add(track);
        }
        continue;
      }
      signatureParts.add(structure.trackPath);
      tracks.add(
        paths.sessionTrackForPath(structure.sessionId, structure.trackPath),
      );
    }
    if (tracks.isEmpty) return;
    final signature = signatureParts.join('|');
    if (_lastPlaybackCoverWarmupSignature == signature) return;
    _lastPlaybackCoverWarmupSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _isReordering ||
          _lastPlaybackCoverWarmupSignature != signature) {
        return;
      }
      warmup.warmupPlaybackCovers(tracks);
    });
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    PlaybackFacade playbackFacade,
  ) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('clear_all_sessions'),
      message: i18n.tr('stop_remove_all_sessions'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('clear_all_sessions'),
      icon: Icons.delete_sweep_rounded,
    );
    if (!confirmed || !mounted) return;
    await playbackFacade.clearAllSessions();
    if (!mounted || !context.mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('all_sessions_cleared'),
      tone: AppFeedbackTone.destructive,
      icon: Icons.delete_sweep_rounded,
    );
  }

  void _openSessionDetail(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }

  void _openQueueEditor(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    showPlaybackQueueEditPanel(context, sessionId);
  }

  @override
  void dispose() {
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    disposeTabState();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
    final playback = ref.read(playbackFacadeProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final warmup = ref.read(audioUiWarmupCoordinatorProvider);
    final PlaylistListState? reorderSnapshot;
    final PlaylistStructureState structureState;
    if (_isReordering) {
      final PlaylistListState snapshot =
          _reorderSnapshot ?? ref.read(playlistListUiProvider);
      reorderSnapshot = snapshot;
      structureState = playlistStructureStateFromListState(snapshot);
    } else {
      reorderSnapshot = null;
      structureState = _isActive
          ? ref.watch(playlistStructureUiProvider)
          : ref.read(playlistStructureUiProvider);
    }
    final settingsState =
        (_isReordering
                ? ref.read(settingsStateProvider)
                : (_isActive
                      ? ref.watch(settingsStateProvider)
                      : ref.read(settingsStateProvider)))
            .value ??
        SettingsState();
    final subtitleSettings = _isReordering
        ? ref.read(subtitleSettingsProvider)
        : (_isActive
              ? ref.watch(subtitleSettingsProvider)
              : ref.read(subtitleSettingsProvider));
    _scheduleInitialPlaceholderDismissal(
      isInitialized: structureState.isInitialized,
    );
    _schedulePlaybackCoverWarmup(structureState, paths, warmup);
    final cardPositionsLocked = settingsState.cardPositionsLocked;
    final coverCacheWidth = coverCacheWidthForResolution(
      settingsState.coverImageResolution,
    );
    final listBottomInset = MobileOverlayInset.of(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final listCacheExtent = playlistListCacheExtent(
      headerHeight: headerHeight,
      viewportWidth: MediaQuery.sizeOf(context).width,
      isLandscape: isLandscape,
    );
    const double expansion = 320.0;
    const topPadding = 4.0 + expansion;
    const bottomPadding = 16.0 + expansion;

    Widget buildSessionItem(BuildContext context, int index) {
      if (index == structureState.entries.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final structure = structureState.entries[index];
      final session = structure.session;
      final cardStateOverride = reorderSnapshot?.cardStateFor(session.id);
      if (reorderSnapshot != null && cardStateOverride == null) {
        return SizedBox.shrink(key: ValueKey(session.id));
      }
      final track = paths.sessionTrackForPath(session.id, structure.trackPath);
      final coverPath = library.resolvedPlaybackCoverPathForTrack(track);
      final child = RepaintBoundary(
        child: structure.isPlaybackQueue
            ? _PlaybackQueueCard(
                session: session,
                cardStateOverride: cardStateOverride,
                library: library,
                playback: playback,
                index: index,
                cardPositionsLocked: cardPositionsLocked,
                coverCacheWidth: coverCacheWidth,
                onOpen: () => session.currentTrackPath.isEmpty
                    ? showAppSnackBar(
                        context,
                        i18n.tr('queue_add_audio_first'),
                        tone: AppFeedbackTone.warning,
                        icon: Icons.queue_music_rounded,
                      )
                    : _openSessionDetail(context, session.id),
                onEdit: () => _openQueueEditor(context, session.id),
              )
            : _SessionListCard(
                sessionId: session.id,
                cardStateOverride: cardStateOverride,
                track: track,
                coverPath: coverPath,
                coverGeneration: structureState.coverGeneration,
                coverCacheWidth: coverCacheWidth,
                showSubtitles: subtitleSettings.isGlobalEnabled(session.id),
                library: library,
                playback: playback,
                index: index,
                cardPositionsLocked: cardPositionsLocked,
                onOpen: () => _openSessionDetail(context, session.id),
              ),
      );
      return KeyedSubtree(key: ValueKey(session.id), child: child);
    }

    return ScrollActivityGate(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: EdgeInsets.only(
                top: headerHeight + 4,
                bottom: listBottomInset,
                right: 4,
              ),
            ),
            child: ContentBoundReorderArea(
              headerHeight: headerHeight,
              bottomInset: listBottomInset,
              topExpansion: expansion,
              bottomExpansion: expansion,
              scrollController: _scrollController,
              showScrollbar: isLandscape,
              scrollbarMainAxisMargin: isLandscape ? 12 : 0,
              child: PlaceholderContentTransition(
                showPlaceholder:
                    !_initialPlaceholderDismissed ||
                    !structureState.isInitialized,
                placeholder: const _PlaylistLoadingSkeleton(
                  key: ValueKey('playlist_initial_placeholder'),
                  topPadding: topPadding,
                  bottomPadding: bottomPadding,
                ),
                content: Stack(
                  key: const ValueKey('playlist_loaded_content'),
                  clipBehavior: Clip.none,
                  children: [
                    if (!structureState.hasSessions)
                      _SessionsEmptyState(
                        key: const ValueKey('empty_state'),
                        bottomInset: 100,
                        topInset: expansion + 64,
                        onOpenLibrary: widget.onOpenLibrary,
                      ),
                    if (structureState.hasSessions)
                      Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(canvasColor: Colors.transparent),
                        child: ReorderAutoScroller(
                          key: const ValueKey('session_list'),
                          scrollController: _scrollController,
                          isDragging: !cardPositionsLocked && _isReordering,
                          contentMarginTop: topPadding,
                          contentMarginBottom: bottomPadding,
                          child: cardPositionsLocked
                              ? ListView.builder(
                                  key: const PageStorageKey<String>(
                                    'playlist_card_positions_list',
                                  ),
                                  controller: _scrollController,
                                  physics: const ClampingScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    topPadding,
                                    16,
                                    bottomPadding,
                                  ),
                                  cacheExtent: listCacheExtent,
                                  clipBehavior: Clip.none,
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: structureState.entries.length + 1,
                                  itemBuilder: buildSessionItem,
                                )
                              : ReorderableListView.builder(
                                  key: const PageStorageKey<String>(
                                    'playlist_card_positions_list',
                                  ),
                                  scrollController: _scrollController,
                                  physics: const ClampingScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    topPadding,
                                    16,
                                    bottomPadding,
                                  ),
                                  cacheExtent: listCacheExtent,
                                  clipBehavior: Clip.none,
                                  autoScrollerVelocityScalar: 0,
                                  buildDefaultDragHandles: false,
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  onReorder: (oldIndex, newIndex) {
                                    ref
                                        .read(playbackFacadeProvider)
                                        .reorderSessions(oldIndex, newIndex);
                                    setState(() {
                                      _isReordering = false;
                                      _reorderSnapshot = null;
                                    });
                                  },
                                  onReorderStart: (_) {
                                    setState(() {
                                      _reorderSnapshot = ref.read(
                                        playlistListUiProvider,
                                      );
                                      _isReordering = true;
                                    });
                                    unawaited(
                                      AppInteractionFeedback.trigger(
                                        AppInteractionFeedbackType.destructive,
                                      ),
                                    );
                                  },
                                  onReorderEnd: (_) {
                                    if (_isReordering) {
                                      setState(() {
                                        _isReordering = false;
                                        _reorderSnapshot = null;
                                      });
                                    }
                                  },
                                  proxyDecorator: (child, index, animation) =>
                                      _buildReorderProxy(
                                        context,
                                        child,
                                        animation,
                                      ),
                                  itemCount: structureState.entries.length + 1,
                                  itemBuilder: buildSessionItem,
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Consumer(
              builder: (context, ref, child) {
                final headerState = _isActive
                    ? ref.watch(playlistHeaderUiProvider)
                    : ref.read(playlistHeaderUiProvider);
                final sessionSummary =
                    '${i18n.tr('sessions_count', {'count': headerState.sessionCount})} · '
                    '${i18n.tr('playing_count', {'count': headerState.playingCount})}';
                return TopPageHeader(
                  key: headerKey,
                  icon: Icons.graphic_eq_rounded,
                  title: i18n.tr('playback_sessions'),
                  subtitle: sessionSummary,
                  subtitleFontSize: 11,
                  fitSubtitleToWidth: true,
                  collapseController: _scrollController,
                  floatingReveal: true,
                  floatingRevealDistance: 56,
                  bottomSpacing: 4,
                  trailing: SizedBox(
                    height: 44,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (headerState.hasTimer)
                          _TimerCountdownCapsule(
                            remaining:
                                headerState.timerRemaining ??
                                headerState.timerDuration ??
                                Duration.zero,
                            active: headerState.timerActive,
                            autoResumeAt: headerState.autoResumeAt,
                            onTap: widget.onTimerTap,
                          )
                        else
                          IconButton(
                            onPressed: widget.onTimerTap,
                            icon: const Icon(Icons.alarm_rounded),
                            tooltip: i18n.tr('timer'),
                          ),
                        UnifiedPopupMenuButton<String>(
                          icon: Icons.more_horiz_rounded,
                          tooltip: i18n.tr('more_actions'),
                          entries: [
                            UnifiedMenuEntry<String>.action(
                              value: 'add_playback_queue',
                              icon: Icons.playlist_add_rounded,
                              label: i18n.tr('add_playback_queue'),
                            ),
                            const UnifiedMenuEntry<String>.divider(),
                            UnifiedMenuEntry<String>.action(
                              value: 'pause_all',
                              icon: Icons.pause_circle_outline_rounded,
                              label: i18n.tr('pause_all_sessions'),
                              enabled: structureState.hasSessions,
                            ),
                            UnifiedMenuEntry<String>.action(
                              value: 'clear_all',
                              icon: Icons.delete_sweep_rounded,
                              label: i18n.tr('clear_all_sessions'),
                              destructive: true,
                              enabled: structureState.hasSessions,
                            ),
                            const UnifiedMenuEntry<String>.divider(),
                            UnifiedMenuEntry<String>.action(
                              value: 'toggle_card_positions_locked',
                              icon: Icons.push_pin_rounded,
                              label: i18n.tr('fixed_card_positions'),
                              trailing: cardPositionsLocked
                                  ? const Icon(Icons.check_rounded, size: 18)
                                  : null,
                            ),
                          ],
                          onSelected: (value) {
                            if (value == 'add_playback_queue') {
                              final queueCount = structureState.entries
                                  .where((entry) => entry.isPlaybackQueue)
                                  .length;
                              ref
                                  .read(playbackFacadeProvider)
                                  .createPlaybackQueue(
                                    i18n.tr('default_playback_queue_name', {
                                      'number': queueCount + 1,
                                    }),
                                  );
                            } else if (value == 'pause_all') {
                              ref
                                  .read(playbackFacadeProvider)
                                  .pauseAllSessions();
                              showAppSnackBar(
                                context,
                                i18n.tr('all_paused'),
                                tone: AppFeedbackTone.warning,
                                icon: Icons.pause_circle_outline_rounded,
                              );
                            } else if (value == 'clear_all') {
                              _confirmClearAll(
                                context,
                                ref.read(playbackFacadeProvider),
                              );
                            } else if (value ==
                                'toggle_card_positions_locked') {
                              unawaited(
                                settings.setCardPositionsLocked(
                                  !cardPositionsLocked,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderProxy(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final animValue = Curves.easeInOut.transform(animation.value);
        final scale = 1.0 + (0.012 * animValue);

        return Transform.scale(scale: scale, child: child);
      },
      child: child,
    );
  }
}
