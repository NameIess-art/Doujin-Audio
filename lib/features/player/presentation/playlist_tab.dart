import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_orientation_controller.dart';
import '../../../app/application/audio_path_coordinator.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/subtitle_settings_provider.dart';
import '../application/playback_facade.dart';
import '../../settings/application/settings_state.dart';
import '../application/playback_session_snapshot.dart';
import '../application/subtitle_overlay_controller.dart';
import '../application/playback_time_segment_service.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/ui/permission_action_controller.dart';
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
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import 'playback_position_ui_gate.dart';
import 'playback_error_text.dart';
import 'session_video_surface.dart';
import 'session_video_viewport.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
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
import 'playlist_sorting.dart';
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
part 'playlist_tab_video.dart';
part 'playlist_tab_volume_timer.dart';
part 'playlist_tab_queue.dart';

// Four 48px Material tap targets plus the loop capsule padding and gaps.
const double _sessionDetailCapsuleWidth = 52;
const double _sessionDetailCapsuleHeight = 212;
const double _sessionDetailCapsuleAnchorOffsetY = 26;
const double sessionVolumeDisplayMaximum = 1.5;
const int sessionVolumeDisplayMaximumPercent = 150;

double sessionVolumeDisplayValueFromGain(double gain) {
  final clampedGain = gain
      .clamp(0.0, PlaybackFacade.maxSessionVolume)
      .toDouble();
  if (clampedGain <= 1) return clampedGain;
  return 1 +
      (clampedGain - 1) *
          ((sessionVolumeDisplayMaximum - 1) /
              (PlaybackFacade.maxSessionVolume - 1));
}

double sessionVolumeGainFromDisplayValue(double displayValue) {
  final clampedDisplayValue = displayValue
      .clamp(0.0, sessionVolumeDisplayMaximum)
      .toDouble();
  if (clampedDisplayValue <= 1) return clampedDisplayValue;
  return 1 +
      (clampedDisplayValue - 1) *
          ((PlaybackFacade.maxSessionVolume - 1) /
              (sessionVolumeDisplayMaximum - 1));
}

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

MusicTrack? resolveSessionSwitcherSelectedTrack({
  required List<MusicTrack> displayedTracks,
  required List<MusicTrack>? queueTracks,
  required String currentPath,
  required int currentQueueIndex,
}) {
  for (final track in displayedTracks) {
    if (PathMatcher.equalsNormalized(track.path, currentPath)) return track;
  }
  if (queueTracks == null ||
      currentQueueIndex < 0 ||
      currentQueueIndex >= queueTracks.length) {
    return null;
  }
  final queuedTrack = queueTracks[currentQueueIndex];
  if (queuedTrack.remoteMetadataKind != 'asmr.one') return null;
  for (final track in displayedTracks) {
    if (_sameSessionSwitcherTrack(track, queuedTrack)) return track;
  }
  return null;
}

bool _sameSessionSwitcherTrack(MusicTrack left, MusicTrack right) {
  if (identical(left, right) ||
      PathMatcher.equalsNormalized(left.path, right.path)) {
    return true;
  }
  if (left.remoteMetadataKind != 'asmr.one' ||
      right.remoteMetadataKind != 'asmr.one') {
    return false;
  }
  final leftRelative = left.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  final rightRelative = right.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  if (leftRelative == null ||
      leftRelative.isEmpty ||
      rightRelative == null ||
      rightRelative.isEmpty ||
      _normalizedRemoteRelativePath(leftRelative) !=
          _normalizedRemoteRelativePath(rightRelative)) {
    return false;
  }
  final leftWorkId = left.remoteMetadata?['id']?.toString().trim();
  final rightWorkId = right.remoteMetadata?['id']?.toString().trim();
  if (leftWorkId?.isNotEmpty == true && rightWorkId?.isNotEmpty == true) {
    return leftWorkId == rightWorkId;
  }
  return left.groupKey.isNotEmpty && left.groupKey == right.groupKey;
}

String _normalizedRemoteRelativePath(String value) =>
    path.posix.normalize(value.replaceAll('\\', '/'));

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
    this.tabIndex = 2,
    this.onTimerTap,
    this.onOpenLibrary,
    this.activeTabIndexListenable,
  });

  final int tabIndex;
  final VoidCallback? onTimerTap;
  final VoidCallback? onOpenLibrary;
  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends ConsumerState<PlaylistTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<PlaylistTab> {
  final ScrollController _scrollController = ScrollController();
  bool _initialPlaceholderDismissed = false;
  bool _initialPlaceholderDismissScheduled = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedSessionIds = <String>{};

  void _enterSelectionMode(String initialSessionId) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedSessionIds.clear();
      _selectedSessionIds.add(initialSessionId);
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(() {
      _isSelectionMode = false;
      _selectedSessionIds.clear();
    });
  }

  void _toggleSessionSelection(String sessionId) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (_selectedSessionIds.contains(sessionId)) {
        _selectedSessionIds.remove(sessionId);
      } else {
        _selectedSessionIds.add(sessionId);
      }
    });
  }

  Future<void> _handleBatchPlay() async {
    if (_selectedSessionIds.isEmpty) return;
    final multiThreadEnabled =
        ref.read(settingsStateProvider).value?.multiThreadPlaybackEnabled ??
        false;
    if (!multiThreadEnabled && _selectedSessionIds.length > 1) return;

    final playback = ref.read(playbackFacadeProvider);
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = _selectedSessionIds.toList();
    for (final id in sessionIds) {
      final cardState = ref.read(playlistSessionCardStateProvider(id));
      if (cardState != null && !cardState.isPlaying) {
        await playback.toggleSessionPlayPause(id);
      }
    }
  }

  Future<void> _handleBatchPause() async {
    if (_selectedSessionIds.isEmpty) return;
    final playback = ref.read(playbackFacadeProvider);
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = _selectedSessionIds.toList();
    for (final id in sessionIds) {
      final cardState = ref.read(playlistSessionCardStateProvider(id));
      if (cardState != null && cardState.isPlaying) {
        await playback.toggleSessionPlayPause(id);
      }
    }
  }

  Future<void> _handleBatchRemove() async {
    if (_selectedSessionIds.isEmpty) return;
    final playback = ref.read(playbackFacadeProvider);
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final toRemove = _selectedSessionIds.toList();
    _exitSelectionMode();
    await playback.removeSessions(toRemove);
    for (final id in toRemove) {
      ref.read(subtitleSettingsProvider.notifier).resetForSession(id);
    }
  }

  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollController;

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == tabIndex;

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return _isActive ? ref.watch(provider) : ref.read(provider);
  }

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
    final cleared = await playbackFacade.clearAllSessions();
    if (!mounted || !context.mounted) return;
    if (!cleared) {
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
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

  Future<void> _openSortOptions() async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final settingsState = ref.read(settingsStateProvider).value;
    final result = await showSortOptionsBottomSheet<PlaylistSortCriterion>(
      context: context,
      options: [
        SortOption(
          value: PlaylistSortCriterion.name,
          label: i18n.tr('sort_name'),
        ),
        SortOption(
          value: PlaylistSortCriterion.voiceActor,
          label: i18n.tr('sort_voice_actor'),
        ),
        SortOption(
          value: PlaylistSortCriterion.releaseDate,
          label: i18n.tr('sort_release_date'),
        ),
        SortOption(
          value: PlaylistSortCriterion.addedAt,
          label: i18n.tr('sort_added_date'),
        ),
      ],
      selectedCriterion:
          settingsState?.playlistSortCriterion ?? PlaylistSortCriterion.name,
      ascending: settingsState?.playlistSortAscending ?? true,
      groupByLibrary: settingsState?.playlistGroupByLibrary ?? false,
      title: i18n.tr('sort_by_title'),
      descriptionLabel: i18n.tr('sort_description'),
      ascendingLabel: i18n.tr('sort_ascending'),
      descendingLabel: i18n.tr('sort_descending'),
      groupByLibraryLabel: i18n.tr('sort_group_by_library'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('confirm'),
    );
    if (!mounted || result == null) return;
    final settings = ref.read(settingsRepositoryProvider);
    await settings.setPlaylistSortOptions(
      criterion: result.criterion,
      ascending: result.ascending,
      groupByLibrary: result.groupByLibrary,
    );
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
    final structureState = _isActive
        ? ref.watch(playlistStructureUiProvider)
        : ref.read(playlistStructureUiProvider);
    _readOrWatch(libraryDetailRevisionProvider);
    final playlistSortCriterion = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.playlistSortCriterion ?? PlaylistSortCriterion.name,
      ),
    );
    final playlistSortAscending = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.playlistSortAscending ?? true,
      ),
    );
    final playlistGroupByLibrary = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.playlistGroupByLibrary ?? false,
      ),
    );
    final coverImageResolution = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.coverImageResolution ?? CoverImageResolution.balanced,
      ),
    );
    final subtitleSettings = _isActive
        ? ref.watch(subtitleSettingsProvider)
        : ref.read(subtitleSettingsProvider);
    _scheduleInitialPlaceholderDismissal(
      isInitialized: structureState.isInitialized,
    );
    final coverCacheWidth = coverCacheWidthForResolution(coverImageResolution);
    final listBottomInset = MobileOverlayInset.of(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final listCacheExtent = playlistListCacheExtent(
      headerHeight: headerHeight,
      viewportWidth: MediaQuery.sizeOf(context).width,
      isLandscape: isLandscape,
    );
    final topPadding = headerHeight + 4.0;
    final bottomPadding = listBottomInset + 16.0;
    final sortedSessions = sortPlaylistSessions(
      sessions: structureState.entries
          .map((entry) => entry.session)
          .toList(growable: false),
      criterion: playlistSortCriterion,
      ascending: playlistSortAscending,
      groupByLibrary: playlistGroupByLibrary,
      library: library,
      trackForSession: (session) =>
          paths.sessionTrackForPath(session.id, session.currentTrackPath),
    );
    final entriesBySessionId = <String, PlaylistStructureEntry>{
      for (final entry in structureState.entries) entry.sessionId: entry,
    };
    final visibleEntries = sortedSessions
        .map((session) => entriesBySessionId[session.id])
        .whereType<PlaylistStructureEntry>()
        .toList(growable: false);

    Widget buildSessionItem(BuildContext context, int index) {
      if (index == visibleEntries.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final structure = visibleEntries[index];
      final session = structure.session;
      final track = paths.sessionTrackForPath(session.id, structure.trackPath);
      final coverPath = library.resolvedPlaybackCoverPathForTrack(track);
      final child = RepaintBoundary(
        child: structure.isPlaybackQueue
            ? _PlaybackQueueCard(
                session: session,
                library: library,
                playback: playback,
                coverCacheWidth: coverCacheWidth,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedSessionIds.contains(session.id),
                onLongPress: () => _enterSelectionMode(session.id),
                onToggleSelect: () => _toggleSessionSelection(session.id),
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
                track: track,
                coverPath: coverPath,
                coverGeneration: structureState.coverGeneration,
                coverCacheWidth: coverCacheWidth,
                showSubtitles: subtitleSettings.isGlobalEnabled(session.id),
                library: library,
                playback: playback,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedSessionIds.contains(session.id),
                onLongPress: () => _enterSelectionMode(session.id),
                onToggleSelect: () => _toggleSessionSelection(session.id),
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
            child: PlaceholderContentTransition(
              showPlaceholder:
                  !_initialPlaceholderDismissed ||
                  !structureState.isInitialized,
              placeholder: _PlaylistLoadingSkeleton(
                key: const ValueKey('playlist_initial_placeholder'),
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
                      bottomInset: bottomPadding,
                      topInset: topPadding,
                      onOpenLibrary: widget.onOpenLibrary,
                    ),
                  if (structureState.hasSessions)
                    ListView.builder(
                      key: const PageStorageKey<String>('playlist_list'),
                      controller: _scrollController,
                      physics: const ClampingScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        _playlistListHorizontalPadding,
                        topPadding,
                        _playlistListHorizontalPadding,
                        bottomPadding,
                      ),
                      cacheExtent: listCacheExtent,
                      clipBehavior: Clip.none,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visibleEntries.length + 1,
                      itemBuilder: buildSessionItem,
                    ),
                ],
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
                final multiThreadEnabled = _readOrWatch(
                  settingsStateProvider.select(
                    (state) => state.value?.multiThreadPlaybackEnabled ?? false,
                  ),
                );

                if (_isSelectionMode) {
                  final count = _selectedSessionIds.length;
                  final isPlayEnabled =
                      count > 0 && (multiThreadEnabled || count <= 1);
                  final isPauseEnabled = count > 0;
                  final isRemoveEnabled = count > 0;

                  return TopPageHeader(
                    key: const ValueKey('playlist_batch_selection_header'),
                    leading: IconButton(
                      key: const ValueKey('exit_selection_button'),
                      onPressed: _exitSelectionMode,
                      icon: const Icon(Icons.close_rounded),
                      tooltip: i18n.tr('cancel'),
                    ),
                    title: count.toString(),
                    padding: AppPageHeaderMetrics.mainTabPadding,
                    trailing: SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            key: const ValueKey('batch_pause_button'),
                            onPressed: isPauseEnabled
                                ? _handleBatchPause
                                : null,
                            icon: const Icon(Icons.pause_rounded),
                            tooltip: i18n.tr('pause'),
                          ),
                          IconButton(
                            key: const ValueKey('batch_play_button'),
                            onPressed: isPlayEnabled ? _handleBatchPlay : null,
                            icon: const Icon(Icons.play_arrow_rounded),
                            tooltip: i18n.tr('play'),
                          ),
                          IconButton(
                            key: const ValueKey('batch_remove_button'),
                            onPressed: isRemoveEnabled
                                ? _handleBatchRemove
                                : null,
                            icon: const Icon(Icons.delete_outline_rounded),
                            tooltip: i18n.tr('remove'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return TopPageHeader(
                  key: headerKey,
                  icon: Icons.graphic_eq_rounded,
                  title: i18n.tr('playback_sessions'),
                  padding: AppPageHeaderMetrics.mainTabPadding,
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
                        IconButton(
                          key: const ValueKey<String>('playlist_sort_button'),
                          onPressed: _openSortOptions,
                          icon: const Icon(Icons.sort_rounded),
                          tooltip: i18n.tr('sort_by'),
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
                          ],
                          onSelected: (value) async {
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
                              final paused = await ref
                                  .read(playbackFacadeProvider)
                                  .pauseAllSessions();
                              if (!context.mounted) return;
                              showAppSnackBar(
                                context,
                                i18n.tr(
                                  paused
                                      ? 'all_paused'
                                      : 'operation_failed_retry',
                                ),
                                tone: paused
                                    ? AppFeedbackTone.warning
                                    : AppFeedbackTone.destructive,
                                icon: paused
                                    ? Icons.pause_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                              );
                            } else if (value == 'clear_all') {
                              await _confirmClearAll(
                                context,
                                ref.read(playbackFacadeProvider),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
